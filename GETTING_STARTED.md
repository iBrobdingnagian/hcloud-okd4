# 🚀 Getting Started — Your First OKD Cluster on Hetzner

Hey! 👋 This guide walks you through everything you need **before** you run the
deploy script — the accounts to create, the tokens to grab, and the tools to
install. No prior OpenShift experience needed. Take it one step at a time and
you'll have a real OKD (community OpenShift) cluster running on Hetzner Cloud.

> Already a pro and just want the flags and internals? See the main
> [`README.md`](README.md). This file is the gentle on-ramp.

---

## 🎯 What you'll end up with

A working OKD 4.16 cluster on Hetzner Cloud with a web console you log into
from your browser, built automatically by one script: `./deploy-okd.sh`.

You can start as small as a **single node** (great for learning, cheap) and
**scale up** later whenever you want.

---

## 🧾 The shopping list (what you need to get)

You'll collect **four things** and paste them into a file called `.env`:

| What | Where it comes from | Looks like |
|------|--------------------|------------|
| 🔑 Hetzner API token | Hetzner Cloud Console | a long random string |
| 🌐 A domain name | any registrar (you probably have one) | `okd4.example.com` |
| ☁️ Cloudflare API token | Cloudflare dashboard | a long random string |
| 🆔 Cloudflare Zone ID | Cloudflare dashboard | a 32-char hex string |

Plus a few **free tools** on your own computer (Docker, `jq`, `oc`, Python).
We'll do the tools last — let's get the accounts sorted first.

---

## Step 1 — 🟥 Get a Hetzner Cloud account + API token

This is the cloud your servers actually run on. It bills by the hour, so a
short lab session costs only a few cents.

1. Sign up at **https://www.hetzner.com/cloud** and add a payment method.
2. In the **Cloud Console** (https://console.hetzner.cloud), create a
   **Project** (e.g. `okd-lab`).
3. Open your project → **Security** (left sidebar) → **API Tokens** tab.
4. Click **Generate API Token**.
   - Give it a name like `okd-deploy`.
   - Set permissions to **Read & Write** ✅ (the script creates and destroys
     servers, so it needs write access).
5. **Copy the token now** — Hetzner shows it only once. 📋

> 💡 Keep this secret. Anyone with it can create servers on your bill.

---

## Step 2 — 🌐 Point a domain at Cloudflare

OKD needs a DNS domain (for the console URL, the API, app routes, etc.). This
project manages those DNS records automatically through **Cloudflare**.

1. Pick a domain you own, or buy a cheap one (any registrar works).
2. Create a free account at **https://dash.cloudflare.com** and click
   **Add a site** — enter your domain and follow the steps to switch its
   **nameservers** to the ones Cloudflare gives you. (This is a one-time setup
   at your registrar; it can take a few minutes to a few hours to activate.)
3. Decide on the **subdomain** you'll give the cluster, e.g.
   `okd4.example.com`. You don't pre-create any records — the script does that.

### 2a. Grab your **Zone ID**

1. In the Cloudflare dashboard, click your domain.
2. On the **Overview** page, scroll down the right-hand sidebar to **API**.
3. Copy the **Zone ID** (32 hex characters). 📋

### 2b. Create a **Cloudflare API token**

1. Top-right profile menu → **My Profile** → **API Tokens**
   (or go to https://dash.cloudflare.com/profile/api-tokens).
2. Click **Create Token** → use the **Edit zone DNS** template.
3. Under **Zone Resources**, select **Include → Specific zone →** your domain.
4. Click **Continue to summary** → **Create Token** → **copy it**. 📋

You'll also note the **email** you log into Cloudflare with — the `.env` asks
for it too.

---

## Step 3 — 🛠️ Install the local tools

These run on **your computer** (or whatever machine you launch the deploy
from). All are free.

| Tool | What it's for | Install |
|------|---------------|---------|
| **Docker** | runs the "toolbox" that does Packer/Terraform/Ansible | https://docs.docker.com/get-docker/ |
| **jq** | reads JSON from the Hetzner/Cloudflare APIs | `brew install jq` / `apt install jq` |
| **oc** | the OpenShift command-line client | https://mirror.openshift.com/pub/openshift-v4/clients/ocp/ (or `brew install openshift-cli`) |
| **Python 3 + PyYAML** | edits the install config | usually preinstalled; `pip3 install pyyaml` if missing |
| **git** | to clone this repo | https://git-scm.com |

> 🐳 **Docker must be running** when you deploy. On Linux the script will try
> `sudo systemctl start docker`; on macOS it opens Docker Desktop for you.

Quick check that the essentials are there:

```bash
docker --version && jq --version && oc version --client && python3 --version
```

---

## Step 4 — 📥 Get the project and fill in `.env`

```bash
git clone <this-repo-url> hcloud-okd4
cd hcloud-okd4
cp .env.example .env
```

Now open `.env` in your editor and fill in the values you collected:

```bash
# from Step 1
HCLOUD_TOKEN=paste-your-hetzner-token-here

# from Step 2 (note: the Cloudflare token goes in TWO places)
CLOUDFLARE_API_TOKEN=paste-your-cloudflare-token-here
CLOUDFLARE_EMAIL=you@example.com
TF_VAR_cloudflare_api_token=paste-the-same-cloudflare-token-here

# the subdomain you chose + the Zone ID from Step 2a
TF_VAR_dns_domain=okd4.example.com
TF_VAR_dns_zone_id=paste-your-zone-id-here
```

You can ignore the rest of the file — the deploy script fills in the topology,
region, server types and release for you based on the profile you pick. ✅

> 🔒 `.env` is git-ignored, so your secrets never get committed. The SSH key
> (`okd4_new_id_rsa`) needed to reach the nodes already ships with the repo.

---

## Step 5 — 🎉 Deploy!

The easiest way to start is interactive — just run:

```bash
./deploy-okd.sh
```

It will walk you through a friendly menu:

- **Profile** — pick **3) Lab** for learning.
- **Topology** — pick **1) 1x0** for a single node (cheapest), or `1x1`, `3x3`, etc.
- **Cost tier** — pick **1) low** to use the cheapest servers that still work.
- **Region**, **release**, **how long it'll run** — it shows live pricing and a
  cost estimate before anything is created. You confirm with `y`.

Want a one-liner instead? A single-node lab in one command:

```bash
./deploy-okd.sh --profile 3 --lab-topology 1x0 --lab-tier low
```

Then go make a coffee ☕ — a full build takes roughly **30–60 minutes** (most
of it is the cluster bootstrapping itself; the script shows progress and
typical durations for each step).

---

## Step 6 — 🔐 Log in to your cluster

When it finishes, the script prints a summary with your **console URL**,
**username**, and **password**. Open the console link in your browser:

```
https://console-openshift-console.apps.okd4.example.com
```

It also offers to create your own **admin user** (recommended) so you're not
stuck using the temporary `kubeadmin` account.

From the terminal:

```bash
export KUBECONFIG=$PWD/ignition/auth/kubeconfig
oc get nodes        # see your cluster nodes
```

---

## Step 7 — 📈 Scale up later (optional)

Started with one node and want more? With the cluster running:

```bash
./deploy-okd.sh --scale --workers 2     # add 2 worker nodes
```

The script notices the existing cluster and offers to scale it (it can also
add monitoring/Grafana or create admin users from the same menu).

---

## Step 8 — 🧹 Tear it down (so you stop paying!)

Hetzner bills per hour, so destroy the cluster when you're done:

```bash
./destroy-okd.sh
```

It asks you to type `yes`, then removes all the servers, the load balancer,
network, firewalls, and DNS records. 💸→0

> ⏰ The deploy script also schedules an **automatic teardown** after the lab
> duration you chose, so an experiment can't quietly run all weekend.

---

## 🆘 Common hiccups

- **"docker is required" / daemon errors** → Docker isn't running. Start
  Docker Desktop (macOS/Windows) or `sudo systemctl start docker` (Linux).
- **"jq is required" / "oc is required"** → install the missing tool (Step 3).
- **DNS / certificate errors right after deploy** → your computer cached the
  old "this name doesn't exist" answer. The script flushes DNS for you, but if
  the console doesn't resolve yet, just wait a few minutes and retry.
- **Image build hangs / "Timeout waiting for SSH"** → your network blocks
  outbound port 22. The script warns about this up front; deploys that reuse an
  existing CoreOS snapshot still work.
- **Login feels stuck after creating an admin user** → the OAuth pods take
  1–3 minutes to reload. The script shows a countdown — give it a moment.

---

## 📚 Where to go next

- [`README.md`](README.md) — every flag, profiles, scaling internals,
  monitoring & Grafana, auto-destroy details.
- `./deploy-okd.sh --help` — the full option list, any time.

Happy clustering! 🎈
