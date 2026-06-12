#!/usr/bin/env python3
"""Generate the provisioned OKD Grafana dashboards (grafana/dashboards/*.json).

Run after changing panels:  python3 grafana/gen-dashboards.py
The deploy script ships whatever JSON files are in grafana/dashboards/.
"""
import json
import os

DS = {"type": "prometheus", "uid": "${datasource}"}


def target(expr, legend="", instant=False, fmt=None):
    t = {"expr": expr, "legendFormat": legend, "instant": instant}
    if fmt:
        t["format"] = fmt
    return t


def _panel(ptype, title, x, y, w, h, targets, unit="short"):
    for i, t in enumerate(targets):
        t["refId"] = chr(ord("A") + i)
        t["datasource"] = DS
    return {
        "type": ptype,
        "title": title,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": targets,
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "options": {},
    }


def ts(title, x, y, w, h, targets, unit="short", max_val=None):
    p = _panel("timeseries", title, x, y, w, h, targets, unit)
    p["fieldConfig"]["defaults"]["custom"] = {
        "fillOpacity": 10, "showPoints": "never", "lineWidth": 1}
    if max_val is not None:
        p["fieldConfig"]["defaults"]["max"] = max_val
        p["fieldConfig"]["defaults"]["min"] = 0
    p["options"] = {"legend": {"displayMode": "list", "placement": "bottom"},
                    "tooltip": {"mode": "multi", "sort": "desc"}}
    return p


def stat(title, x, y, w, h, targets, unit="short", thresholds=None):
    p = _panel("stat", title, x, y, w, h, targets, unit)
    p["options"] = {"reduceOptions": {"calcs": ["lastNotNull"]},
                    "colorMode": "value", "graphMode": "area"}
    steps = thresholds or [{"color": "green", "value": None}]
    p["fieldConfig"]["defaults"]["thresholds"] = {"mode": "absolute", "steps": steps}
    return p


def gauge(title, x, y, w, h, targets):
    p = _panel("gauge", title, x, y, w, h, targets, "percentunit")
    p["options"] = {"reduceOptions": {"calcs": ["lastNotNull"]}}
    p["fieldConfig"]["defaults"]["max"] = 1
    p["fieldConfig"]["defaults"]["min"] = 0
    p["fieldConfig"]["defaults"]["thresholds"] = {"mode": "absolute", "steps": [
        {"color": "green", "value": None},
        {"color": "yellow", "value": 0.7},
        {"color": "red", "value": 0.85}]}
    return p


def table(title, x, y, w, h, targets):
    p = _panel("table", title, x, y, w, h, targets)
    p["options"] = {"footer": {"show": False}}
    return p


def var_datasource():
    return {"name": "datasource", "label": "Datasource", "type": "datasource",
            "query": "prometheus", "hide": 0,
            "current": {"selected": False, "text": "OpenShift Prometheus",
                        "value": "OpenShift Prometheus"}}


def var_query(name, query, include_all=True):
    return {"name": name, "type": "query", "datasource": DS,
            "query": {"query": query, "refId": name}, "refresh": 2,
            "multi": True, "includeAll": include_all, "sort": 1,
            "current": {"selected": True, "text": ["All"], "value": ["$__all"]}}


def dashboard(uid, title, panels, variables):
    return {
        "uid": uid, "title": title, "schemaVersion": 39, "version": 1,
        "refresh": "30s", "time": {"from": "now-3h", "to": "now"},
        "timezone": "browser", "editable": True,
        "templating": {"list": variables},
        "panels": panels,
    }


NET_DEV = 'device!~"lo|veth.*|br-.*|ovn.*|genev_sys.*|tun.*"'

overview = dashboard("okd-cluster-overview", "OKD / Cluster Overview", [
    stat("Nodes Ready", 0, 0, 4, 4,
         [target('sum(kube_node_status_condition{condition="Ready",status="true"})')]),
    stat("Pods Running", 4, 0, 4, 4,
         [target('sum(kube_pod_status_phase{phase="Running"})')]),
    stat("Firing Alerts", 8, 0, 4, 4,
         [target('count(ALERTS{alertstate="firing"}) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None},
                     {"color": "yellow", "value": 2},
                     {"color": "red", "value": 5}]),
    gauge("Cluster CPU", 12, 0, 4, 4,
          [target('1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))')]),
    gauge("Cluster Memory", 16, 0, 4, 4,
          [target('1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)')]),
    gauge("Cluster Disk (/)", 20, 0, 4, 4,
          [target('1 - sum(node_filesystem_avail_bytes{mountpoint="/"}) / sum(node_filesystem_size_bytes{mountpoint="/"})')]),

    ts("CPU usage per node", 0, 4, 12, 8,
       [target('1 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))', "{{instance}}")],
       unit="percentunit", max_val=1),
    ts("Memory usage per node", 12, 4, 12, 8,
       [target('1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes', "{{instance}}")],
       unit="percentunit", max_val=1),

    ts("Network throughput per node", 0, 12, 12, 8,
       [target(f'sum by(instance)(rate(node_network_receive_bytes_total{{{NET_DEV}}}[5m]))', "rx {{instance}}"),
        target(f'sum by(instance)(rate(node_network_transmit_bytes_total{{{NET_DEV}}}[5m]))', "tx {{instance}}")],
       unit="Bps"),
    ts("Root disk usage per node", 12, 12, 12, 8,
       [target('1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}', "{{instance}}")],
       unit="percentunit", max_val=1),

    ts("Top 10 pods by CPU", 0, 20, 12, 8,
       [target('topk(10, sum by(namespace,pod)(rate(container_cpu_usage_seconds_total{container!="",pod!=""}[5m])))',
               "{{namespace}}/{{pod}}")]),
    ts("Top 10 pods by memory", 12, 20, 12, 8,
       [target('topk(10, sum by(namespace,pod)(container_memory_working_set_bytes{container!="",pod!=""}))',
               "{{namespace}}/{{pod}}")], unit="bytes"),

    ts("API server request rate by code", 0, 28, 8, 8,
       [target('sum by(code)(rate(apiserver_request_total[5m]))', "{{code}}")], unit="reqps"),
    ts("API server p99 latency by verb", 8, 28, 8, 8,
       [target('histogram_quantile(0.99, sum by(le,verb)(rate(apiserver_request_duration_seconds_bucket{verb!~"WATCH|CONNECT"}[5m])))',
               "{{verb}}")], unit="s"),
    ts("API server 5xx rate", 16, 28, 8, 8,
       [target('sum(rate(apiserver_request_total{code=~"5.."}[5m])) OR on() vector(0)', "5xx")], unit="reqps"),

    stat("etcd has leader", 0, 36, 4, 4,
         [target('min(etcd_server_has_leader)')],
         thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}]),
    stat("etcd leader changes (1h)", 4, 36, 4, 4,
         [target('max(increase(etcd_server_leader_changes_seen_total[1h]))')],
         thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 3}]),
    ts("etcd DB size", 8, 36, 8, 8,
       [target('etcd_mvcc_db_total_size_in_bytes', "{{pod}}")], unit="bytes"),
    ts("etcd p99 backend commit latency", 16, 36, 8, 8,
       [target('histogram_quantile(0.99, sum by(le,pod)(rate(etcd_disk_backend_commit_duration_seconds_bucket[5m])))',
               "{{pod}}")], unit="s"),

    table("Firing alerts", 0, 44, 24, 8,
          [target('ALERTS{alertstate="firing"}', instant=True, fmt="table")]),
], [var_datasource()])

nodes = dashboard("okd-nodes", "OKD / Nodes", [
    ts("CPU usage", 0, 0, 12, 8,
       [target('1 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle",instance=~"$node"}[5m]))', "{{instance}}")],
       unit="percentunit", max_val=1),
    ts("Load average", 12, 0, 12, 8,
       [target('node_load1{instance=~"$node"}', "1m {{instance}}"),
        target('node_load5{instance=~"$node"}', "5m {{instance}}"),
        target('node_load15{instance=~"$node"}', "15m {{instance}}")]),
    ts("Memory used", 0, 8, 12, 8,
       [target('node_memory_MemTotal_bytes{instance=~"$node"} - node_memory_MemAvailable_bytes{instance=~"$node"}',
               "used {{instance}}"),
        target('node_memory_MemTotal_bytes{instance=~"$node"}', "total {{instance}}")], unit="bytes"),
    ts("Memory usage %", 12, 8, 12, 8,
       [target('1 - node_memory_MemAvailable_bytes{instance=~"$node"} / node_memory_MemTotal_bytes{instance=~"$node"}',
               "{{instance}}")], unit="percentunit", max_val=1),
    ts("Disk I/O", 0, 16, 12, 8,
       [target('rate(node_disk_read_bytes_total{instance=~"$node"}[5m])', "read {{instance}} {{device}}"),
        target('rate(node_disk_written_bytes_total{instance=~"$node"}[5m])', "write {{instance}} {{device}}")],
       unit="Bps"),
    ts("Network throughput", 12, 16, 12, 8,
       [target(f'sum by(instance)(rate(node_network_receive_bytes_total{{instance=~"$node",{NET_DEV}}}[5m]))', "rx {{instance}}"),
        target(f'sum by(instance)(rate(node_network_transmit_bytes_total{{instance=~"$node",{NET_DEV}}}[5m]))', "tx {{instance}}")],
       unit="Bps"),
    ts("Filesystem usage by mountpoint", 0, 24, 24, 8,
       [target('1 - node_filesystem_avail_bytes{instance=~"$node",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{instance=~"$node",fstype!~"tmpfs|overlay"}',
               "{{instance}} {{mountpoint}}")], unit="percentunit", max_val=1),
], [var_datasource(), var_query("node", "label_values(node_cpu_seconds_total, instance)")])

workloads = dashboard("okd-workloads", "OKD / Workloads", [
    stat("Pods Running", 0, 0, 6, 4,
         [target('sum(kube_pod_status_phase{namespace=~"$namespace",phase="Running"}) OR on() vector(0)')]),
    stat("Pods Pending", 6, 0, 6, 4,
         [target('sum(kube_pod_status_phase{namespace=~"$namespace",phase="Pending"}) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 1}]),
    stat("Pods Failed", 12, 0, 6, 4,
         [target('sum(kube_pod_status_phase{namespace=~"$namespace",phase="Failed"}) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}]),
    stat("Container restarts (1h)", 18, 0, 6, 4,
         [target('sum(increase(kube_pod_container_status_restarts_total{namespace=~"$namespace"}[1h])) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 1},
                     {"color": "red", "value": 5}]),
    ts("CPU by pod", 0, 4, 12, 8,
       [target('sum by(pod)(rate(container_cpu_usage_seconds_total{namespace=~"$namespace",container!="",pod!=""}[5m]))',
               "{{pod}}")]),
    ts("Memory by pod", 12, 4, 12, 8,
       [target('sum by(pod)(container_memory_working_set_bytes{namespace=~"$namespace",container!="",pod!=""})',
               "{{pod}}")], unit="bytes"),
    ts("Network by pod", 0, 12, 12, 8,
       [target('sum by(pod)(rate(container_network_receive_bytes_total{namespace=~"$namespace"}[5m]))', "rx {{pod}}"),
        target('sum by(pod)(rate(container_network_transmit_bytes_total{namespace=~"$namespace"}[5m]))', "tx {{pod}}")],
       unit="Bps"),
    ts("Container restarts by pod (1h)", 12, 12, 12, 8,
       [target('sum by(pod)(increase(kube_pod_container_status_restarts_total{namespace=~"$namespace"}[1h]))',
               "{{pod}}")]),
    ts("PVC usage", 0, 20, 24, 8,
       [target('kubelet_volume_stats_used_bytes{namespace=~"$namespace"} / kubelet_volume_stats_capacity_bytes{namespace=~"$namespace"}',
               "{{namespace}}/{{persistentvolumeclaim}}")], unit="percentunit", max_val=1),
], [var_datasource(), var_query("namespace", "label_values(kube_pod_info, namespace)")])

outdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards")
os.makedirs(outdir, exist_ok=True)
for d in (overview, nodes, workloads):
    path = os.path.join(outdir, d["uid"] + ".json")
    with open(path, "w") as f:
        json.dump(d, f, indent=1, sort_keys=True)
        f.write("\n")
    print(f"wrote {path} ({len(d['panels'])} panels)")
