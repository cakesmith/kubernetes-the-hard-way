# Argo CD on the AWS lab

Argo CD runs inside the lab. It polls the public house-price-predictor repository
over HTTPS and applies the Helm chart to the `house-price` namespace. GitHub
Actions publishes the API image and updates the lab values file in Git.

## Bootstrap

1. Open `make kube-tunnel` in a separate terminal and select the lab kubeconfig.
   Install CoreDNS at Service IP `10.0.0.10` and configure both worker kubelets
   with that cluster DNS address and the domain `cluster.local`. The API serving
   certificate must cover the actual `kubernetes` Service IP, `10.0.0.1` in
   this lab. Test DNS and HTTPS from fresh pods on both workers before installing
   Argo CD.
2. Install the pinned non-HA Argo CD release. Keep the UI on its ClusterIP
   Service and use a local port forward.

   ```bash
   export KUBECONFIG="$HOME/.kube/kthw-aws.yaml"
   kubectl apply --server-side -k gitops/argocd/install
   kubectl -n argocd rollout status deployment --timeout=5m
   kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m
   kubectl -n argocd port-forward svc/argocd-server 8443:443
   ```

3. Create the `house-price` namespace if it is absent. When adopting an
   existing release, capture its running image digests, disable the old Helm
   deploy job, and omit the Application's automated sync policy for the first
   sync. Inspect the diff, sync with pruning disabled, and verify `Synced`,
   `Healthy`, and a real prediction through Streamlit before enabling
   automatic sync.

   ```bash
   kubectl apply --server-side -f gitops/argocd/apps
   kubectl -n argocd get application house-price
   kubectl -n house-price port-forward svc/house-price-streamlit 8501:8501
   ```

## Releases and rollback

The application tracks `main` and
`deployment/kubernetes/house-price-model/values-kthw-lab.yaml`. The repository
requires the **Validate lab Helm chart** check on `main`. The MLOps workflow
validates the promotion commit on a temporary branch before pushing it to
`main`. Argo CD reconciles to the latest desired revision when the lab starts.
Revert the promotion commit to return to the previous API digest.
