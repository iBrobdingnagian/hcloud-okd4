#!/usr/bin/env python3
"""Generate the provisioned OKD Grafana dashboards.

Output layout (one subdirectory per Grafana folder):
    grafana/dashboards/<category>/<uid>.json

Run after changing panels:  python3 grafana/gen-dashboards.py
The deploy script ships one ConfigMap per category and the provisioning
provider maps each directory to a Grafana folder of the same name.
"""
import json
import os
import shutil

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
REAL_FS = 'fstype!~"tmpfs|overlay"'

# ── Cluster ───────────────────────────────────────────────────────────────

overview = dashboard("okd-cluster-overview", "Cluster Overview", [
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
], [var_datasource()])

capacity = dashboard("okd-cluster-capacity", "Cluster Capacity", [
    stat("Allocatable vCPU", 0, 0, 6, 4,
         [target('sum(kube_node_status_allocatable{resource="cpu"})')]),
    stat("Allocatable memory", 6, 0, 6, 4,
         [target('sum(kube_node_status_allocatable{resource="memory"})')], unit="bytes"),
    stat("CPU requests committed", 12, 0, 6, 4,
         [target('sum(kube_pod_container_resource_requests{resource="cpu"}) / sum(kube_node_status_allocatable{resource="cpu"})')],
         unit="percentunit",
         thresholds=[{"color": "green", "value": None},
                     {"color": "yellow", "value": 0.8},
                     {"color": "red", "value": 0.95}]),
    stat("Memory requests committed", 18, 0, 6, 4,
         [target('sum(kube_pod_container_resource_requests{resource="memory"}) / sum(kube_node_status_allocatable{resource="memory"})')],
         unit="percentunit",
         thresholds=[{"color": "green", "value": None},
                     {"color": "yellow", "value": 0.8},
                     {"color": "red", "value": 0.95}]),
    ts("CPU requests vs allocatable per node", 0, 4, 12, 8,
       [target('sum by(node)(kube_pod_container_resource_requests{resource="cpu"}) / on(node) kube_node_status_allocatable{resource="cpu"}',
               "{{node}}")], unit="percentunit", max_val=1),
    ts("Memory requests vs allocatable per node", 12, 4, 12, 8,
       [target('sum by(node)(kube_pod_container_resource_requests{resource="memory"}) / on(node) kube_node_status_allocatable{resource="memory"}',
               "{{node}}")], unit="percentunit", max_val=1),
    ts("Pods per node vs capacity", 0, 12, 12, 8,
       [target('count by(node)(kube_pod_info)', "pods {{node}}"),
        target('kube_node_status_allocatable{resource="pods"}', "max {{node}}")]),
    ts("CPU limits overcommit", 12, 12, 12, 8,
       [target('sum(kube_pod_container_resource_limits{resource="cpu"}) / sum(kube_node_status_allocatable{resource="cpu"})', "cpu limits"),
        target('sum(kube_pod_container_resource_limits{resource="memory"}) / sum(kube_node_status_allocatable{resource="memory"})', "memory limits")],
       unit="percentunit"),
], [var_datasource()])

alerts = dashboard("okd-cluster-alerts", "Cluster Alerts", [
    stat("Firing", 0, 0, 6, 4,
         [target('count(ALERTS{alertstate="firing"}) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None},
                     {"color": "yellow", "value": 2},
                     {"color": "red", "value": 5}]),
    stat("Pending", 6, 0, 6, 4,
         [target('count(ALERTS{alertstate="pending"}) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None},
                     {"color": "yellow", "value": 3}]),
    stat("Critical firing", 12, 0, 6, 4,
         [target('count(ALERTS{alertstate="firing",severity="critical"}) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None},
                     {"color": "red", "value": 1}]),
    stat("Alertmanager replicas up", 18, 0, 6, 4,
         [target('sum(up{job="alertmanager-main"}) OR on() vector(0)')],
         thresholds=[{"color": "red", "value": None},
                     {"color": "green", "value": 1}]),
    ts("Alerts by severity", 0, 4, 12, 8,
       [target('sum by(severity)(ALERTS{alertstate="firing"}) OR on() vector(0)', "{{severity}}")]),
    ts("Alerts by namespace", 12, 4, 12, 8,
       [target('sum by(namespace)(ALERTS{alertstate="firing"})', "{{namespace}}")]),
    table("Firing alerts", 0, 12, 24, 10,
          [target('ALERTS{alertstate="firing"}', instant=True, fmt="table")]),
    table("Pending alerts", 0, 22, 24, 8,
          [target('ALERTS{alertstate="pending"}', instant=True, fmt="table")]),
], [var_datasource()])

# ── Control Plane ─────────────────────────────────────────────────────────

control_plane = dashboard("okd-control-plane", "API Server & etcd", [
    stat("etcd has leader", 0, 0, 4, 4,
         [target('min(etcd_server_has_leader)')],
         thresholds=[{"color": "red", "value": None}, {"color": "green", "value": 1}]),
    stat("etcd leader changes (1h)", 4, 0, 4, 4,
         [target('max(increase(etcd_server_leader_changes_seen_total[1h]))')],
         thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 3}]),
    stat("etcd failed proposals (1h)", 8, 0, 4, 4,
         [target('max(increase(etcd_server_proposals_failed_total[1h])) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}]),
    stat("API server 5xx (5m)", 12, 0, 6, 4,
         [target('sum(rate(apiserver_request_total{code=~"5.."}[5m])) OR on() vector(0)')],
         unit="reqps",
         thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}]),
    stat("Scheduler pending pods", 18, 0, 6, 4,
         [target('sum(scheduler_pending_pods) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 1}]),
    ts("API server request rate by code", 0, 4, 8, 8,
       [target('sum by(code)(rate(apiserver_request_total[5m]))', "{{code}}")], unit="reqps"),
    ts("API server p99 latency by verb", 8, 4, 8, 8,
       [target('histogram_quantile(0.99, sum by(le,verb)(rate(apiserver_request_duration_seconds_bucket{verb!~"WATCH|CONNECT"}[5m])))',
               "{{verb}}")], unit="s"),
    ts("API server in-flight requests", 16, 4, 8, 8,
       [target('sum by(request_kind)(apiserver_current_inflight_requests)', "{{request_kind}}")]),
    ts("etcd DB size", 0, 12, 8, 8,
       [target('etcd_mvcc_db_total_size_in_bytes', "{{pod}}")], unit="bytes"),
    ts("etcd p99 backend commit latency", 8, 12, 8, 8,
       [target('histogram_quantile(0.99, sum by(le,pod)(rate(etcd_disk_backend_commit_duration_seconds_bucket[5m])))',
               "{{pod}}")], unit="s"),
    ts("etcd p99 WAL fsync latency", 16, 12, 8, 8,
       [target('histogram_quantile(0.99, sum by(le,pod)(rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])))',
               "{{pod}}")], unit="s"),
    ts("etcd raft proposals", 0, 20, 12, 8,
       [target('sum(rate(etcd_server_proposals_committed_total[5m]))', "committed"),
        target('sum(rate(etcd_server_proposals_applied_total[5m]))', "applied"),
        target('sum(rate(etcd_server_proposals_failed_total[5m]))', "failed")]),
    ts("etcd network peer round-trip p99", 12, 20, 12, 8,
       [target('histogram_quantile(0.99, sum by(le,pod)(rate(etcd_network_peer_round_trip_time_seconds_bucket[5m])))',
               "{{pod}}")], unit="s"),
], [var_datasource()])

# ── Nodes (all / masters / workers share the same panel set) ──────────────


def node_dashboard(uid, title, pattern):
    sel = f'instance=~"$node"'
    return dashboard(uid, title, [
        ts("CPU usage", 0, 0, 12, 8,
           [target(f'1 - avg by(instance)(rate(node_cpu_seconds_total{{mode="idle",{sel}}}[5m]))', "{{instance}}")],
           unit="percentunit", max_val=1),
        ts("Load average", 12, 0, 12, 8,
           [target(f'node_load1{{{sel}}}', "1m {{instance}}"),
            target(f'node_load5{{{sel}}}', "5m {{instance}}"),
            target(f'node_load15{{{sel}}}', "15m {{instance}}")]),
        ts("Memory used", 0, 8, 12, 8,
           [target(f'node_memory_MemTotal_bytes{{{sel}}} - node_memory_MemAvailable_bytes{{{sel}}}', "used {{instance}}"),
            target(f'node_memory_MemTotal_bytes{{{sel}}}', "total {{instance}}")], unit="bytes"),
        ts("Memory usage %", 12, 8, 12, 8,
           [target(f'1 - node_memory_MemAvailable_bytes{{{sel}}} / node_memory_MemTotal_bytes{{{sel}}}', "{{instance}}")],
           unit="percentunit", max_val=1),
        ts("Disk I/O", 0, 16, 12, 8,
           [target(f'rate(node_disk_read_bytes_total{{{sel}}}[5m])', "read {{instance}} {{device}}"),
            target(f'rate(node_disk_written_bytes_total{{{sel}}}[5m])', "write {{instance}} {{device}}")],
           unit="Bps"),
        ts("Network throughput", 12, 16, 12, 8,
           [target(f'sum by(instance)(rate(node_network_receive_bytes_total{{{sel},{NET_DEV}}}[5m]))', "rx {{instance}}"),
            target(f'sum by(instance)(rate(node_network_transmit_bytes_total{{{sel},{NET_DEV}}}[5m]))', "tx {{instance}}")],
           unit="Bps"),
        ts("Filesystem usage by mountpoint", 0, 24, 24, 8,
           [target(f'1 - node_filesystem_avail_bytes{{{sel},{REAL_FS}}} / node_filesystem_size_bytes{{{sel},{REAL_FS}}}',
                   "{{instance}} {{mountpoint}}")], unit="percentunit", max_val=1),
    ], [var_datasource(),
        var_query("node", f'label_values(node_cpu_seconds_total{{instance=~"{pattern}"}}, instance)')])


nodes_all = node_dashboard("okd-nodes", "All Nodes", ".*")
nodes_masters = node_dashboard("okd-masters", "Masters", "master.*")
nodes_workers = node_dashboard("okd-workers", "Workers", "worker.*")

# ── Workloads ─────────────────────────────────────────────────────────────

workloads = dashboard("okd-workloads", "Workloads by Namespace", [
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
], [var_datasource(), var_query("namespace", "label_values(kube_pod_info, namespace)")])

pods_health = dashboard("okd-pods-health", "Pods Health", [
    stat("Not-ready pods", 0, 0, 6, 4,
         [target('sum(kube_pod_status_ready{condition="false"}) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 1},
                     {"color": "red", "value": 5}]),
    stat("Pending pods", 6, 0, 6, 4,
         [target('sum(kube_pod_status_phase{phase="Pending"}) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 1}]),
    stat("OOMKilled containers (present)", 12, 0, 6, 4,
         [target('sum(kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}]),
    stat("Restarts cluster-wide (1h)", 18, 0, 6, 4,
         [target('sum(increase(kube_pod_container_status_restarts_total[1h])) OR on() vector(0)')],
         thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 1},
                     {"color": "red", "value": 10}]),
    ts("Pods by phase", 0, 4, 12, 8,
       [target('sum by(phase)(kube_pod_status_phase)', "{{phase}}")]),
    ts("Waiting containers by reason", 12, 4, 12, 8,
       [target('sum by(reason)(kube_pod_container_status_waiting_reason) OR on() vector(0)', "{{reason}}")]),
    ts("Top 10 pods by restarts (1h)", 0, 12, 12, 8,
       [target('topk(10, sum by(namespace,pod)(increase(kube_pod_container_status_restarts_total[1h])))',
               "{{namespace}}/{{pod}}")]),
    ts("Containers last terminated by reason", 12, 12, 12, 8,
       [target('sum by(reason)(kube_pod_container_status_last_terminated_reason) OR on() vector(0)', "{{reason}}")]),
    table("Not-ready pods (excluding Succeeded)", 0, 20, 24, 8,
          [target('kube_pod_status_ready{condition="false"} == 1', instant=True, fmt="table")]),
], [var_datasource()])

# ── Network ───────────────────────────────────────────────────────────────

network = dashboard("okd-network", "Cluster Network", [
    stat("Cluster ingress", 0, 0, 6, 4,
         [target(f'sum(rate(node_network_receive_bytes_total{{{NET_DEV}}}[5m]))')], unit="Bps"),
    stat("Cluster egress", 6, 0, 6, 4,
         [target(f'sum(rate(node_network_transmit_bytes_total{{{NET_DEV}}}[5m]))')], unit="Bps"),
    stat("TCP retransmits /s", 12, 0, 6, 4,
         [target('sum(rate(node_netstat_Tcp_RetransSegs[5m]))')],
         thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 50},
                     {"color": "red", "value": 200}]),
    stat("Conntrack usage", 18, 0, 6, 4,
         [target('max(node_nf_conntrack_entries / node_nf_conntrack_entries_limit)')],
         unit="percentunit",
         thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 0.7},
                     {"color": "red", "value": 0.9}]),
    ts("Throughput per node", 0, 4, 12, 8,
       [target(f'sum by(instance)(rate(node_network_receive_bytes_total{{{NET_DEV}}}[5m]))', "rx {{instance}}"),
        target(f'sum by(instance)(rate(node_network_transmit_bytes_total{{{NET_DEV}}}[5m]))', "tx {{instance}}")],
       unit="Bps"),
    ts("Packet drops per node", 12, 4, 12, 8,
       [target(f'sum by(instance)(rate(node_network_receive_drop_total{{{NET_DEV}}}[5m]))', "rx drop {{instance}}"),
        target(f'sum by(instance)(rate(node_network_transmit_drop_total{{{NET_DEV}}}[5m]))', "tx drop {{instance}}")],
       unit="pps"),
    ts("Top 10 pods by receive", 0, 12, 12, 8,
       [target('topk(10, sum by(namespace,pod)(rate(container_network_receive_bytes_total[5m])))',
               "{{namespace}}/{{pod}}")], unit="Bps"),
    ts("Top 10 pods by transmit", 12, 12, 12, 8,
       [target('topk(10, sum by(namespace,pod)(rate(container_network_transmit_bytes_total[5m])))',
               "{{namespace}}/{{pod}}")], unit="Bps"),
    ts("TCP retransmits per node", 0, 20, 12, 8,
       [target('rate(node_netstat_Tcp_RetransSegs[5m])', "{{instance}}")]),
    ts("Conntrack entries per node", 12, 20, 12, 8,
       [target('node_nf_conntrack_entries', "{{instance}}"),
        target('node_nf_conntrack_entries_limit', "limit {{instance}}")]),
], [var_datasource()])

# ── Storage ───────────────────────────────────────────────────────────────

storage = dashboard("okd-storage", "Cluster Storage", [
    gauge("Worst root disk", 0, 0, 6, 4,
          [target('max(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})')]),
    gauge("Worst inode usage", 6, 0, 6, 4,
          [target(f'max(1 - node_filesystem_files_free{{{REAL_FS}}} / node_filesystem_files{{{REAL_FS}}})')]),
    stat("Cluster disk reads", 12, 0, 6, 4,
         [target('sum(rate(node_disk_read_bytes_total[5m]))')], unit="Bps"),
    stat("Cluster disk writes", 18, 0, 6, 4,
         [target('sum(rate(node_disk_written_bytes_total[5m]))')], unit="Bps"),
    ts("Disk throughput per node", 0, 4, 12, 8,
       [target('sum by(instance)(rate(node_disk_read_bytes_total[5m]))', "read {{instance}}"),
        target('sum by(instance)(rate(node_disk_written_bytes_total[5m]))', "write {{instance}}")],
       unit="Bps"),
    ts("IOPS per node", 12, 4, 12, 8,
       [target('sum by(instance)(rate(node_disk_reads_completed_total[5m]))', "read {{instance}}"),
        target('sum by(instance)(rate(node_disk_writes_completed_total[5m]))', "write {{instance}}")],
       unit="iops"),
    ts("Disk I/O saturation (time spent doing I/O)", 0, 12, 12, 8,
       [target('rate(node_disk_io_time_seconds_total[5m])', "{{instance}} {{device}}")],
       unit="percentunit", max_val=1),
    ts("Filesystem usage per node", 12, 12, 12, 8,
       [target(f'1 - node_filesystem_avail_bytes{{{REAL_FS}}} / node_filesystem_size_bytes{{{REAL_FS}}}',
               "{{instance}} {{mountpoint}}")], unit="percentunit", max_val=1),
    ts("Inode usage per node", 0, 20, 12, 8,
       [target(f'1 - node_filesystem_files_free{{{REAL_FS}}} / node_filesystem_files{{{REAL_FS}}}',
               "{{instance}} {{mountpoint}}")], unit="percentunit", max_val=1),
    ts("PVC usage (all namespaces)", 12, 20, 12, 8,
       [target('kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes',
               "{{namespace}}/{{persistentvolumeclaim}}")], unit="percentunit", max_val=1),
], [var_datasource()])

# ── write files: one directory per Grafana folder ─────────────────────────

FOLDERS = {
    "cluster": [overview, capacity, alerts],
    "control-plane": [control_plane],
    "nodes": [nodes_all, nodes_masters, nodes_workers],
    "workloads": [workloads, pods_health],
    "network": [network],
    "storage": [storage],
}

basedir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards")
shutil.rmtree(basedir, ignore_errors=True)
total = 0
for folder, dashboards in FOLDERS.items():
    outdir = os.path.join(basedir, folder)
    os.makedirs(outdir, exist_ok=True)
    for d in dashboards:
        path = os.path.join(outdir, d["uid"] + ".json")
        with open(path, "w") as f:
            json.dump(d, f, indent=1, sort_keys=True)
            f.write("\n")
        total += 1
        print(f"wrote {folder}/{d['uid']}.json ({len(d['panels'])} panels)")
print(f"{total} dashboards in {len(FOLDERS)} folders")
