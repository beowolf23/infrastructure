kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml


kubectl apply -f configmap/argocd-cmd-params-cm.yaml

# reposerver.disable.tls only takes effect if --client-ca-path is also
# cleared - the repo-server binary defaults that flag to a non-empty path
# regardless of env vars, which then conflicts with --disable-tls at startup.
kubectl patch deployment argocd-repo-server -n argocd --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["/usr/local/bin/argocd-repo-server","--client-ca-path="]}]'

kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl rollout restart statefulset argocd-application-controller -n argocd
kubectl rollout restart deployment argocd-server -n argocd
