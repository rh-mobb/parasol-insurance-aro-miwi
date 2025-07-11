#!/bin/bash

user_count=$(oc get namespaces | grep showroom | wc -l)

# create fake showroom users
if [[ $user_count == "0" ]]; then
for i in $(seq 1 25);
do
    htpasswd -c -B -b users.htpasswd $i openshift
    oc create namespace showroom-user$i
done

oc create secret generic htpass-secret --from-file=htpasswd=users.htpasswd -n openshift-config


cat << EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: my_htpasswd_provider
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
EOF
fi

# Get user count
user_count=$(oc get namespaces | grep showroom | wc -l)

echo -n 'Waiting for minio-root-user secret'
while [ -z "\$(oc get secret -n ic-shared-minio minio-root-user -oname 2>/dev/null)" ]; do
  echo -n .
  sleep 5
done; echo

echo -n 'Waiting for rhods-dashboard route'
while [ -z "\$(oc get route -n redhat-ods-applications rhods-dashboard -oname 2>/dev/null)" ]; do
  echo -n .
  sleep 5
done; echo

# Get needed variables
MINIO_ROOT_USER=$(oc get secret minio-root-user -n ic-shared-minio -o template --template '{{.data.MINIO_ROOT_USER|base64decode}}')
MINIO_ROOT_PASSWORD=$(oc get secret minio-root-user -n ic-shared-minio -o template --template '{{.data.MINIO_ROOT_PASSWORD|base64decode}}')
MINIO_HOST=https://$(oc get route minio-s3 -n ic-shared-minio -o template --template '{{.spec.host}}')
DASHBOARD_ROUTE=https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')

# Define some variables
WORKBENCH_NAME="my-workbench"
WORKBENCH_IMAGE="ic-workbench:miwi"
# WORKBENCH_IMAGE="rhoai-lab-insurance-claim-workbench:miwi"
PIPELINE_ENGINE="Tekton"

for i in $(seq 6 11) ; #$(seq 1 $user_count);
do

# Construct dynamic variables
USER_NAME="user$i"
USER_PROJECT="user$i"

echo "Generating and apply resources for $USER_NAME..."

# Create projects
cat << EOF | oc apply -f-
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  annotations:
    openshift.io/description: ''
    openshift.io/display-name: $USER_PROJECT
  labels:
    kubernetes.io/metadata.name: $USER_PROJECT
    # modelmesh-enabled: 'true'
    opendatahub.io/dashboard: 'true'
  name: $USER_PROJECT
spec:
  finalizers:
  - kubernetes
EOF

# Apply role bindings
cat << EOF | oc apply -f-
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: admin
  namespace: $USER_PROJECT
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: $USER_NAME
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: demo-setup
  namespace: $USER_PROJECT
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: demo-setup-edit
  namespace: $USER_PROJECT
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
- kind: ServiceAccount
  name: demo-setup
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: demo-setup-route-reader-binding-$USER_PROJECT
subjects:
- kind: ServiceAccount
  name: demo-setup
  namespace: $USER_PROJECT
roleRef:
  kind: ClusterRole
  name: route-reader
  apiGroup: rbac.authorization.k8s.io
---
EOF

# Create the workbench PVC
cat << EOF | oc apply -f-
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  annotations:
    openshift.io/description: ''
    openshift.io/display-name: My Workbench
    volume.beta.kubernetes.io/storage-provisioner: openshift-storage.rbd.csi.ceph.com
    volume.kubernetes.io/storage-provisioner: openshift-storage.rbd.csi.ceph.com
  name: $WORKBENCH_NAME
  namespace: $USER_PROJECT
  finalizers:
    - kubernetes.io/pvc-protection
  labels:
    opendatahub.io/dashboard: 'true'
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  volumeMode: Filesystem
EOF

# Create the workbench
cat << EOF | oc apply -f-
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  annotations:
    notebooks.opendatahub.io/inject-oauth: 'true'
    opendatahub.io/image-display-name: CUSTOM - Insurance Claim Processing Lab Workbench
    notebooks.opendatahub.io/oauth-logout-url: >-
      $DASHBOARD_ROUTE/projects/$USER_PROJECT?notebookLogout=$WORKBENCH_NAME
    opendatahub.io/accelerator-name: ''
    openshift.io/description: ''
    openshift.io/display-name: My Workbench
    notebooks.opendatahub.io/last-image-selection: '$WORKBENCH_IMAGE'
    notebooks.opendatahub.io/last-size-selection: Standard
    opendatahub.io/username: $USER_NAME
  name: $WORKBENCH_NAME
  namespace: $USER_PROJECT
  labels:
    app: $WORKBENCH_NAME
    opendatahub.io/dashboard: 'true'
    opendatahub.io/odh-managed: 'true'
    opendatahub.io/user: $USER_NAME
    azure.workload.identity/use: "true"
spec:
  template:
    spec:
      affinity: {}
      containers:
        - resources:
            limits:
              cpu: '2'
              memory: 8Gi
            requests:
              cpu: '1'
              memory: 6Gi
          readinessProbe:
            failureThreshold: 3
            httpGet:
              path: /notebook/$USER_PROJECT/$WORKBENCH_NAME/api
              port: notebook-port
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 5
            successThreshold: 1
            timeoutSeconds: 1
          name: $WORKBENCH_NAME
          livenessProbe:
            failureThreshold: 3
            httpGet:
              path: /notebook/$USER_PROJECT/$WORKBENCH_NAME/api
              port: notebook-port
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 5
            successThreshold: 1
            timeoutSeconds: 1
          env:
            - name: NOTEBOOK_ARGS
              value: |-
                --ServerApp.port=8888
                                  --ServerApp.token=''
                                  --ServerApp.password=''
                                  --ServerApp.base_url=/notebook/$USER_PROJECT/$WORKBENCH_NAME
                                  --ServerApp.quit_button=False
                                  --ServerApp.tornado_settings={"user":"$USER_NAME","hub_host":"$DASHBOARD_ROUTE","hub_prefix":"/projects/$USER_PROJECT"}
            - name: JUPYTER_IMAGE
              value: >-
                image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/$WORKBENCH_IMAGE
          ports:
            - containerPort: 8888
              name: notebook-port
              protocol: TCP
          imagePullPolicy: Always
          volumeMounts:
            - mountPath: /opt/app-root/src
              name: $WORKBENCH_NAME
            - mountPath: /dev/shm
              name: shm
          image: >-
            image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/$WORKBENCH_IMAGE
          workingDir: /opt/app-root/src
        - resources:
            limits:
              cpu: 100m
              memory: 64Mi
            requests:
              cpu: 100m
              memory: 64Mi
          readinessProbe:
            failureThreshold: 3
            httpGet:
              path: /oauth/healthz
              port: oauth-proxy
              scheme: HTTPS
            initialDelaySeconds: 5
            periodSeconds: 5
            successThreshold: 1
            timeoutSeconds: 1
          name: oauth-proxy
          livenessProbe:
            failureThreshold: 3
            httpGet:
              path: /oauth/healthz
              port: oauth-proxy
              scheme: HTTPS
            initialDelaySeconds: 30
            periodSeconds: 5
            successThreshold: 1
            timeoutSeconds: 1
          env:
            - name: NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          ports:
            - containerPort: 8443
              name: oauth-proxy
              protocol: TCP
          imagePullPolicy: Always
          volumeMounts:
            - mountPath: /etc/oauth/config
              name: oauth-config
            - mountPath: /etc/tls/private
              name: tls-certificates
          image: >-
            registry.redhat.io/openshift4/ose-oauth-proxy@sha256:4bef31eb993feb6f1096b51b4876c65a6fb1f4401fee97fa4f4542b6b7c9bc46
          args:
            - '--provider=openshift'
            - '--https-address=:8443'
            - '--http-address='
            - '--openshift-service-account=$WORKBENCH_NAME'
            - '--cookie-secret-file=/etc/oauth/config/cookie_secret'
            - '--cookie-expire=24h0m0s'
            - '--tls-cert=/etc/tls/private/tls.crt'
            - '--tls-key=/etc/tls/private/tls.key'
            - '--upstream=http://localhost:8888'
            - '--upstream-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
            - '--email-domain=*'
            - '--skip-provider-button'
            - >-
              --openshift-sar={"verb":"get","resource":"notebooks","resourceAPIGroup":"kubeflow.org","resourceName":"$WORKBENCH_IMAGE","namespace":"$USER_PROJECT"}
            - >-
              --logout-url=$DASHBOARD_ROUTE/projects/$USER_PROJECT?notebookLogout=$WORKBENCH_IMAGE
      enableServiceLinks: false
      serviceAccountName: $WORKBENCH_NAME
      tolerations:
        - effect: NoSchedule
          key: notebooksonly
          operator: Exists
      volumes:
        - name: $WORKBENCH_NAME
          persistentVolumeClaim:
            claimName: $WORKBENCH_NAME
        - emptyDir:
            medium: Memory
          name: shm
        - name: oauth-config
          secret:
            defaultMode: 420
            secretName: $WORKBENCH_NAME-oauth-config
        - name: tls-certificates
          secret:
            defaultMode: 420
            secretName: $WORKBENCH_NAME-tls
  readyReplicas: 1
EOF

# Git clone job
cat << EOF | oc apply -f-
apiVersion: batch/v1
kind: Job
metadata:
  name: clone-repo
  namespace: $USER_PROJECT
spec:
  backoffLimit: 4
  template:
    spec:
      serviceAccount: demo-setup
      serviceAccountName: demo-setup
      initContainers:
      - name: wait-for-workbench
        image: image-registry.openshift-image-registry.svc:5000/openshift/tools:latest
        imagePullPolicy: IfNotPresent
        command: ["/bin/bash"]
        args:
        - -ec
        - |-
          echo -n "Waiting for workbench pod in $USER_PROJECT namespace"
          while [ -z "\$(oc get pods -n $USER_PROJECT -l app=$WORKBENCH_NAME -o custom-columns=STATUS:.status.phase --no-headers | grep Running 2>/dev/null)" ]; do
              echo -n '.'
              sleep 1
          done
          echo "Workbench pod is running in $USER_PROJECT namespace"
      containers:
      - name: git-clone
        image: image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/s2i-generic-data-science-notebook:1.2
        imagePullPolicy: IfNotPresent
        command: ["/bin/bash"]
        args:
        - -ec
        - |-
          pod_name=\$(oc get pods --selector=app=$WORKBENCH_NAME -o jsonpath='{.items[0].metadata.name}') && oc exec \$pod_name -- git clone https://github.com/rh-mobb/parasol-insurance-aro-miwi parasol-insurance
      restartPolicy: Never
EOF

# argocd
cat <<EOF | oc apply -f -
---
apiVersion: argoproj.io/v1alpha1
kind: ArgoCD
metadata:
  name: argocd
  namespace: $USER_PROJECT
spec:
  sso:
    dex:
      openShiftOAuth: true
      resources:
        limits:
          cpu: 500m
          memory: 256Mi
        requests:
          cpu: 250m
          memory: 128Mi
    provider: dex
  rbac:
    defaultPolicy: "role:readonly"
    policy: "g, system:authenticated, role:admin"
    scopes: "[groups]"
  server:
    insecure: true
    route:
      enabled: true
      tls:
        insecureEdgeTerminationPolicy: Redirect
        termination: edge
EOF

sleep 20

done