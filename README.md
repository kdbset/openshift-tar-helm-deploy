# Deploy a container image `.tar.gz` and Helm chart to OpenShift from Windows

This guide covers deploying an application to OpenShift from a Windows machine when you have:

- a container image saved as a `.tar.gz` (made with `docker save` or `podman save`)
- a Helm chart for the application
- **no** Docker, Podman or WSL on the machine

All commands are for PowerShell.

The overall flow:

1. Push the image archive into OpenShift's internal image registry (Option A or B).
2. Install the Helm chart, pointing it at the pushed image.
3. Expose the app with a Route.

---

## Quick start: one script

`deploy-openshift.ps1` runs every step below for you. Run it and answer the prompts:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-openshift.ps1
```

It asks for the image archive, the chart, the OpenShift API URL (if you're not logged in) and the project. It reads the image name and tag from the archive and offers them as defaults. Then it:

1. installs `helm` with winget if it's missing
2. logs in to OpenShift and creates the project if needed
3. pushes the image with `crane` (downloaded automatically), or falls back to a temporary in-cluster `skopeo` pod
4. runs `helm upgrade --install` with the image settings pointed at the pushed image and OpenShift-safe security settings, and waits for the pods
5. creates an HTTPS route if the app has none, and prints the URL

To run it without prompts, pass the values as parameters:

```powershell
.\deploy-openshift.ps1 -ImageArchive .\myapp.tar.gz -ChartPath .\mychart -Project myproj `
    -Server https://api.mycluster.example.com:6443 -Token <token> -NonInteractive
```

| Parameter | Use |
|---|---|
| `-PushMethod Auto\|Crane\|InCluster` | How to push the image. `Auto` (default) tries crane, then the in-cluster pod. |
| `-AppName`, `-ImageTag`, `-ReleaseName` | Override the names read from the archive. |
| `-ValuesFile` | Extra Helm values file. |
| `-ImageRepositoryKey`, `-ImageTagKey`, `-ImagePullPolicyKey` | Use these if the chart's image keys aren't `image.repository` / `image.tag` / `image.pullPolicy`. |
| `-KeepChartSecurityContext` | Keep the chart's `runAsUser`/`fsGroup` settings instead of clearing them. |
| `-ExposeRoute $false`, `-ServiceToExpose` | Skip route creation, or choose which service gets the route. |
| `-InsecureRegistry $false` | Verify the registry's TLS certificate when pushing with crane. |
| `-SkopeoImage` | Use an internal mirror of the skopeo image on clusters without internet access. |

The rest of this guide explains the same steps done by hand.

---

## Prerequisites

- The `oc` CLI, logged in to your cluster
- `helm.exe`: run `winget install Helm.Helm`, or download it from the Helm releases page on GitHub
- An OpenShift project (namespace) to deploy into

```powershell
oc login https://api.<cluster>:6443 -u <user>
oc new-project myproj      # or: oc project myproj
```

The examples below use these names. Replace them with your own.

| Placeholder | Meaning |
|---|---|
| `myproj` | OpenShift project / namespace |
| `myapp` | image and release name |
| `1.0` | image tag |
| `myapp.tar.gz` | your image archive |
| `.\mychart` | your Helm chart folder or `.tgz` |

---

## Step 1: Push the image to the OpenShift registry

### Option A: `crane` (one small .exe, nothing to install)

`crane` (from Google's go-containerregistry project) pushes a `docker save` archive straight to a registry.

**1. Download crane.** Get `go-containerregistry_Windows_x86_64.tar.gz` from the go-containerregistry releases page on GitHub, then unpack it. Windows 10 and 11 include `tar`:

```powershell
tar -xzf .\go-containerregistry_Windows_x86_64.tar.gz crane.exe
```

**2. Decompress the image archive.** `crane` expects a plain `.tar`:

```powershell
$in  = [IO.File]::OpenRead("$PWD\myapp.tar.gz")
$out = [IO.File]::Create("$PWD\myapp.tar")
$gz  = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
$gz.CopyTo($out); $gz.Close(); $out.Close()
```

**3. Find the registry's external address:**

```powershell
$REG = oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}'
```

If that route doesn't exist, a cluster admin has to expose it first. Note the escaped quotes, which PowerShell needs:

```powershell
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{\"spec\":{\"defaultRoute\":true}}'
```

**4. Log in and push:**

```powershell
.\crane.exe auth login $REG -u (oc whoami) -p (oc whoami -t)
.\crane.exe push .\myapp.tar "$REG/myproj/myapp:1.0" --insecure   # drop --insecure if the registry cert is trusted
```

### Option B: Copy it inside the cluster (only `oc` needed)

Use this if you can't download tools, or if the registry route isn't exposed. It starts a temporary pod with `skopeo`, copies the archive into it, and pushes from inside the cluster.

```powershell
cd <folder with myapp.tar.gz>     # oc cp works best with relative paths on Windows
oc project myproj
oc run skopeo --image=quay.io/skopeo/stable --restart=Never --command -- sleep infinity
oc wait --for=condition=Ready pod/skopeo

oc cp .\myapp.tar.gz skopeo:/tmp/myapp.tar.gz

$T = oc whoami -t
oc exec skopeo -- skopeo copy `
  docker-archive:/tmp/myapp.tar.gz `
  docker://image-registry.openshift-image-registry.svc:5000/myproj/myapp:1.0 `
  --dest-creds "user:$T" --dest-tls-verify=false

oc delete pod skopeo
```

`skopeo` reads the gzipped archive directly, so no decompression is needed. The pod must be able to pull `quay.io/skopeo/stable`. If your cluster has no internet access, use an internal mirror of that image.

### Check the push

```powershell
oc get is myapp -n myproj
```

You should see an ImageStream with tag `1.0`.

---

## Step 2: Deploy with Helm

### Find the chart's image settings

```powershell
helm show values .\mychart
```

Look for the `image:` block. Most charts use `image.repository`, `image.tag` and `image.pullPolicy`. Some charts use a separate `image.registry` key or nest the image under a component name. Use whatever keys this chart defines.

### Create `values-openshift.yaml`

```yaml
image:
  repository: image-registry.openshift-image-registry.svc:5000/myproj/myapp
  tag: "1.0"
  pullPolicy: Always

# OpenShift assigns its own non-root user ID. Hardcoded IDs in the chart will be rejected.
podSecurityContext:
  runAsUser: null
  fsGroup: null
securityContext:
  runAsUser: null
```

Use the registry's **internal** address here (`image-registry.openshift-image-registry.svc:5000`), not the external route you pushed to. Pods in the same project can pull from it with no extra credentials.

### Install

```powershell
helm install myapp .\mychart -n myproj -f values-openshift.yaml
oc get pods -n myproj -w
```

To roll out changes later:

```powershell
helm upgrade myapp .\mychart -n myproj -f values-openshift.yaml
```

---

## Step 3: Expose the app

- **If the chart creates an Ingress** (`ingress.enabled: true`): OpenShift turns it into a Route automatically. Set `ingress.hosts` to a hostname under your cluster's apps domain, such as `myapp.apps.<cluster-domain>`.
- **If it doesn't:** create a route yourself:

```powershell
oc expose service/<service-name> -n myproj
oc get route -n myproj
```

---

## Troubleshooting

| Problem | Cause and fix |
|---|---|
| Pods rejected: `unable to validate against any security context constraint` | The chart still sets a user ID, adds capabilities, or uses `hostPath`/`hostNetwork`. Null out every `runAsUser`/`runAsGroup`, including on init containers. Last resort: a cluster admin runs `oc adm policy add-scc-to-user anyuid -z <serviceaccount> -n myproj`. |
| Pod crashes with permission errors | OpenShift runs containers as a random non-root user ID. The image must not need root or write to root-owned folders. The usual Dockerfile fix is `chgrp -R 0 /app && chmod -R g=u /app`. |
| `ImagePullBackOff` | The repository path or tag doesn't match what you pushed. Check with `oc get is myapp -n myproj`. If the image lives in another project, grant pull access: `oc policy add-role-to-user system:image-puller system:serviceaccount:myproj:default -n <image-project>`. |
| `exec format error` | The image was built for a different CPU type than the cluster, for example arm64 on an amd64 cluster. |
| Certificate errors when pushing | The registry uses a self-signed cert. Use `--insecure` with crane or `--dest-tls-verify=false` with skopeo, or trust the cluster's CA. |
| `chart requires kubeVersion` | The chart checks the Kubernetes version. Run `oc version` to see which version your cluster is on. |
| Archive is not an image | The file was made with `docker export` (a container filesystem), not `docker save`. It needs to be rebuilt as an image with a container tool before these steps can work. |
