# Configuring kubectl for Remote Access

In this lab you will generate a kubeconfig file for the `kubectl` command line utility based on the `admin` user credentials.

> Run the admin configuration and verification on the `jumpbox`. The [AWS workstation setup](#aws-workstation-access) runs on your workstation.

## The Admin Kubernetes Configuration File

Each kubeconfig requires a Kubernetes API Server to connect to.

You should be able to ping `server.kubernetes.local` based on the `/etc/hosts` DNS entry from a previous lab.

**AWS infrastructure add-on.** The `/etc/hosts` entry from the compute setup resolves `server.kubernetes.local`. Use the API request below to verify TCP and TLS connectivity because the AWS security groups do not allow ping.

```bash
curl --cacert ca.crt \
  https://server.kubernetes.local:6443/version
```

```text
{
  "major": "1",
  "minor": "32",
  "gitVersion": "v1.32.3",
  "gitCommit": "32cc146f75aad04beaaa245a7157eb35063a9f99",
  "gitTreeState": "clean",
  "buildDate": "2025-03-11T19:52:21Z",
  "goVersion": "go1.23.6",
  "compiler": "gc",
  "platform": "linux/arm64"
}
```

Generate a kubeconfig file suitable for authenticating as the `admin` user:

```bash
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server=https://server.kubernetes.local:6443

  kubectl config set-credentials admin \
    --client-certificate=admin.crt \
    --client-key=admin.key

  kubectl config set-context kubernetes-the-hard-way \
    --cluster=kubernetes-the-hard-way \
    --user=admin

  kubectl config use-context kubernetes-the-hard-way
}
```
The results of running the command above should create a kubeconfig file in the default location `~/.kube/config` used by the  `kubectl` commandline tool. This also means you can run the `kubectl` command without specifying a config.


## Verification

Check the version of the remote Kubernetes cluster:

```bash
kubectl version
```

```text
Client Version: v1.32.3
Kustomize Version: v5.5.0
Server Version: v1.32.3
```

List the nodes in the remote Kubernetes cluster:

```bash
kubectl get nodes
```

```
NAME     STATUS   ROLES    AGE    VERSION
node-0   Ready    <none>   10m   v1.32.3
node-1   Ready    <none>   10m   v1.32.3
```

## AWS workstation access

Complete the jumpbox setup above and configure the [SSM-backed `jumpbox` SSH alias](../infrastructure/terraform/README.md#set-up-ssh-aliases) first. The lab must be running, and your workstation needs `kubectl`. Run the following from the repository root on your workstation. If you use Windows with WSL, run it in WSL.

```bash
make kube-tunnel
```

If `~/.kube/kthw-aws.yaml` is missing, the target needs passwordless `sudo` on the jumpbox to export the admin kubeconfig with its certificate and key embedded. It saves the file with permissions limited to your user. Later runs reuse that file. The target selects `kubernetes-the-hard-way` in the lab file and forwards `127.0.0.1:16443` to the private Kubernetes API on port 6443.

Keep that terminal open. In a second workstation terminal, verify access:

```bash
kubectl --kubeconfig="$HOME/.kube/kthw-aws.yaml" get nodes
kubectl --kubeconfig="$HOME/.kube/kthw-aws.yaml" get pods -A
```

### Make the lab your default in Bash

Add this line to `~/.bashrc` once. Put the lab file first so its current context takes precedence and your other contexts are still available.

```bash
export KUBECONFIG="$HOME/.kube/kthw-aws.yaml:$HOME/.kube/config"
```

In any terminal that was already open, run `source ~/.bashrc`. Then verify that plain `kubectl` uses the lab:

```bash
kubectl config current-context
kubectl get nodes
```

Expect `kubernetes-the-hard-way` as the current context. If an error still names `kubernetes.docker.internal:6443`, check the context and reload `~/.bashrc` in that terminal. If the connection is refused on `127.0.0.1:16443`, check the tunnel terminal for SSH errors and rerun `make kube-tunnel` once the port is free. Press Ctrl+C in the tunnel terminal to disconnect. Run `make kube-tunnel` again the next time you need workstation access.

Next: [Provisioning Pod Network Routes](11-pod-network-routes.md)
