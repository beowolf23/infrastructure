kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml


kubectl apply -f configmap/argocd-cmd-params-cm.yaml
kubectl rollout restart deployment argocd-server -n argocd
