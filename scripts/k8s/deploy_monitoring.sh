#!/usr/bin/env bash

# For additional information on the GPU Monitoring tools see:
# https://github.com/NVIDIA/gpu-monitoring-tools
# https://ngc.nvidia.com/catalog/helm-charts/nvidia:gpu-operator
# https://ngc.nvidia.com/catalog/containers/nvidia:k8s:dcgm-exporter
# https://github.com/prometheus-community/helm-charts

# Ensure we start in the correct working directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="${SCRIPT_DIR}/../.."
cd "${ROOT_DIR}" || exit 1

# Source common libraries and env variables
source ${ROOT_DIR}/scripts/common.sh

# Allow overriding config dir to look in
DEEPOPS_CONFIG_DIR=${DEEPOPS_CONFIG_DIR:-"${ROOT_DIR}/config"}

if [ ! -d "${DEEPOPS_CONFIG_DIR}" ]; then
        echo "Can't find configuration in ${DEEPOPS_CONFIG_DIR}"
        echo "Please set DEEPOPS_CONFIG_DIR env variable to point to config location"
        exit 1
fi

HELM_CHARTS_REPO_PROMETHEUS="${HELM_CHARTS_REPO_PROMETHEUS:-https://prometheus-community.github.io/helm-charts}"
HELM_PROMETHEUS_CHART_VERSION="${HELM_PROMETHEUS_CHART_VERSION:-39.5.0}"
ingress_name="ingress-nginx"

PROMETHEUS_YAML_CONFIG="${PROMETHEUS_YAML_CONFIG:-${DEEPOPS_CONFIG_DIR}/helm/monitoring.yml}"
PROMETHEUS_YAML_NO_PERSIST_CONFIG="${PROMETHEUS_YAML_NO_PERSIST_CONFIG:-${DEEPOPS_CONFIG_DIR}/helm/monitoring-no-persist.yml}"
DCGM_CONFIG_CSV="${DCGM_CONFIG_CSV:-${DEEPOPS_CONFIG_DIR}/files/k8s-cluster/dcgm-custom-metrics.csv}"

GPU_OPERATOR_NAMESPACE="${GPU_OPERATOR_NAMESPACE:-gpu-operator}"

function help_me() {
    echo "This script installs the DCGM exporter, Prometheus, Grafana, and configures a GPU Grafana dashboard."
    echo "Default credentials are username: 'admin', password: 'deepops'."
    echo ""
    echo "Usage:"
    echo "-h      This message."
    echo "-p      Print monitoring URLs."
    echo "-d      Delete monitoring namespace and crds. Note, this may delete PVs storing prometheus metrics."
    echo "-x      Disable persistent data, this deploys Prometheus with no PV backing resulting in a loss of data across reboots."
    echo "-w      Wait and poll the grafana/prometheus/alertmanager URLs until they properly return."
    echo "delete  Legacy positional argument for delete. Same as -d flag."
}

function get_opts() {
    while getopts "hdpxw" option; do
        case $option in
            d)
                delete_monitoring
                exit 0
                ;;
            p)
                print_monitoring
                exit 0
                ;;
            h)
                help_me
                exit 1
                ;;
            x)
		PROMETHEUS_YAML_CONFIG="${PROMETHEUS_YAML_NO_PERSIST_CONFIG}"
		PROMETHEUS_NO_PERSIST="true"
                ;;
            w)
                poll_monitoring_url
                exit 0
                ;;
            * )
                # Leave this here to preserve legacy positional args behavior
                if [ "${1}" == "delete" ]; then
                    delete_monitoring
                    exit 0
                else
                    help_me
                    exit 1
                fi
                ;;
        esac
    done
}

function delete_monitoring() {
    helm uninstall prometheus-operator
    helm uninstall kube-prometheus-stack -n monitoring
    helm uninstall "${ingress_name}"
    helm uninstall "nginx-ingress" # Delete legacy naming
    helm uninstall "ingress-nginx" # Delete legacy namespace
    helm uninstall "ingress-nginx" -n deepops-ingress
    kubectl delete crd prometheuses.monitoring.coreos.com
    kubectl delete crd prometheusrules.monitoring.coreos.com
    kubectl delete crd servicemonitors.monitoring.coreos.com
    kubectl delete crd podmonitors.monitoring.coreos.com
    kubectl delete crd alertmanagers.monitoring.coreos.com
    kubectl delete crd thanosrulers.monitoring.coreos.com
    kubectl delete ns monitoring
}

function setup_prom_monitoring() {
    # Add Helm prometheus-community repo if it doesn't exist
    if ! helm repo list | grep prometheus-community >/dev/null 2>&1 ; then
        helm repo add prometheus-community "${HELM_CHARTS_REPO_PROMETHEUS}"
    fi

    # Configure air-gapped deployment
    helm_prom_oper_args=""
    if [ "${PROMETHEUS_OPER_REPO}" ]; then
        helm_prom_oper_args="${helm_prom_oper_args} --set-string image.repository="${PROMETHEUS_OPER_REPO}""
    fi
    helm_kube_prom_args=""
    if [ "${ALERTMANAGER_REPO}" ]; then
        helm_kube_prom_args="${helm_kube_prom_args} --set-string alertmanager.image.repository="${ALERTMANAGER_REPO}""
    fi
    if [ "${PROMETHEUS_REPO}" ]; then
        helm_kube_prom_args="${helm_kube_prom_args} --set-string prometheus.image.repository="${PROMETHEUS_REPO}""
    fi
    if [ "${GRAFANA_REPO}" ]; then
        helm_kube_prom_args="${helm_kube_prom_args} --set-string grafana.image.repository="${GRAFANA_REPO}""
    fi
    if [ "${GRAFANA_WATCHER_REPO}" ]; then
        helm_kube_prom_args="${helm_kube_prom_args} --set-string grafana.grafanaWatcher.repository="${GRAFANA_WATCHER_REPO}""
    fi

    # Deploy the ingress controller with a set name
    NGINX_INGRESS_APP_NAME="${ingress_name}" ./scripts/k8s/deploy_ingress.sh

    # Get IP information of master and ingress
    get_ips

    if kubectl describe service -l "app.kubernetes.io/name=${ingress_name},app.kubernetes.io/component=controller" | grep 'LoadBalancer Ingress' >/dev/null 2>&1; then
        lb_ip="$(kubectl describe service -l "app.kubernetes.io/name=${ingress_name},app.kubernetes.io/component=controller" | grep 'LoadBalancer Ingress' | awk '{print $3}')"
        ingress_ip_string="$(echo ${lb_ip} | tr '.' '-').nip.io"
        echo "Using load balancer url: ${ingress_ip_string}"
    fi

    # Deploy Monitoring stack via Prometheus Operator Helm chart
    echo
    echo "Deploying monitoring stack..."
    if ! kubectl get ns monitoring >/dev/null 2>&1 ; then
        kubectl create ns monitoring
    fi
    if ! helm status -n monitoring kube-prometheus-stack >/dev/null 2>&1 ; then
        helm upgrade --install \
            kube-prometheus-stack \
            prometheus-community/kube-prometheus-stack \
            --version "${HELM_PROMETHEUS_CHART_VERSION}" \
            --namespace monitoring \
            --values "${PROMETHEUS_YAML_CONFIG}" \
            --set alertmanager.ingress.hosts[0]="alertmanager-${ingress_ip_string}" \
            --set prometheus.ingress.hosts[0]="prometheus-${ingress_ip_string}" \
            --set grafana.ingress.hosts[0]="grafana-${ingress_ip_string}" \
	    --timeout 1200s \
            ${helm_prom_oper_args} \
            ${helm_kube_prom_args}
    fi
}

function setup_gpu_monitoring_dashboard() {
    # Create GPU Dashboard config map
    if ! kubectl -n monitoring get configmap kube-prometheus-grafana-gpu >/dev/null 2>&1 ; then
        kubectl create configmap kube-prometheus-grafana-gpu --from-file=${ROOT_DIR}/src/dashboards/gpu-dashboard.json -n monitoring
        kubectl -n monitoring label configmap kube-prometheus-grafana-gpu grafana_dashboard=1
    fi
}

function setup_gpu_monitoring() {
    # Create DCGM metrics config map
    if ! kubectl -n monitoring get configmap dcgm-custom-metrics >/dev/null 2>&1 ; then
        kubectl create configmap dcgm-custom-metrics --from-file=${DCGM_CONFIG_CSV} -n monitoring
    fi

    # Label GPU nodes
    for node in $(kubectl get node --no-headers -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com\\/gpu | grep -v none | awk '{print $1}') ; do
        kubectl label nodes ${node} hardware-type=NVIDIAGPU --overwrite >/dev/null
    done

    # Deploy DCGM node exporter
    if kubectl -n monitoring get pod -l app=dcgm-exporter 2>&1 | grep "No resources found." >/dev/null 2>&1 ; then
        if [ "${DCGM_DOCKER_REGISTRY}" ]; then
            cat workloads/services/k8s/dcgm-exporter.yml \
            | sed "s/image: quay.io/image: ${DCGM_DOCKER_REGISTRY}/g" \
            | sed "s/image: nvcr.io/image: ${DCGM_DOCKER_REGISTRY}/g" \
            | kubectl create -f -
        else
            kubectl create -f workloads/services/k8s/dcgm-exporter.yml
        fi
    fi
}

function get_ips(){
    # Get IP information
    master_ip=$(kubectl get nodes -l node-role.kubernetes.io/master= --no-headers -o custom-columns=IP:.status.addresses.*.address | cut -f1 -d, | head -1)
    ingress_ip_string="$(echo ${master_ip} | tr '.' '-').nip.io"
}

function print_monitoring() {
    get_ips

    # Get Grafana auth details
    grafana_user=$(kubectl -n monitoring get secrets kube-prometheus-stack-grafana -o 'go-template={{ index .data "admin-user" }}' | base64 -d)
    grafana_password=$(kubectl -n monitoring get secrets kube-prometheus-stack-grafana -o 'go-template={{ index .data "admin-password" }}' | base64 -d)

    # Use NodePort directly if the IP string uses the master IP, otherwise use Ingress URL
    if echo "${ingress_ip_string}" | grep "${master_ip}" >/dev/null 2>&1; then
        grafana_port=$(kubectl -n monitoring get svc kube-prometheus-stack-grafana --no-headers -o custom-columns=PORT:.spec.ports.*.nodePort)
        prometheus_port=$(kubectl -n monitoring get svc kube-prometheus-stack-prometheus --no-headers -o custom-columns=PORT:.spec.ports.*.nodePort)
        alertmanager_port=$(kubectl -n monitoring get svc kube-prometheus-stack-alertmanager --no-headers -o custom-columns=PORT:.spec.ports.*.nodePort)

        export grafana_url="http://${master_ip}:${grafana_port}/"
        export prometheus_url="http://${master_ip}:${prometheus_port}/"
        export alertmanager_url="http://${master_ip}:${alertmanager_port}/"
    else
        export grafana_url="http://grafana-${ingress_ip_string}/"
        export prometheus_url="http://prometheus-${ingress_ip_string}/"
        export alertmanager_url="http://alertmanager-${ingress_ip_string}/"
    fi

    echo
    echo "Grafana: ${grafana_url}     admin user: ${grafana_user}     admin password: ${grafana_password}"
    echo "Prometheus: ${prometheus_url}"
    echo "Alertmanager: ${alertmanager_url}"
}


function install_dependencies() {
    # kubect/K8s
    kubectl version
    if [ $? -ne 0 ] ; then
        echo "Unable to talk to Kubernetes API"
        exit 1
    fi

    # Install/initialize Helm if needed
    ./scripts/k8s/install_helm.sh
    # StorageClasse (for volumes and MySQL DB)
    kubectl get storageclass 2>&1 | grep "(default)" >/dev/null 2>&1
    if [ $? -ne 0 ] ; then
        echo "No storageclass found"
	echo "This is required to persist Prometheus data"
	echo ""
	if [ "${PROMETHEUS_NO_PERSIST}" ]; then
	    echo "WARNING: Persistence has been disabled, rebooting or migrating the Prometheus Pod will result in loss of all data"
	    sleep 5 # Sleep to give the user time to see a warning
	else
            echo "To continue without persistent storage, run '${0} -x'"
            echo "To setup the nfs-client-provisioner (preferred), run: ansible-playbook playbooks/k8s-cluster/nfs-client-provisioner.yml"
            echo "To provision Ceph storage, run: ./scripts/k8s/deploy_rook.sh"
            exit 1
	fi
    fi
}


function poll_monitoring_url() {
    print_monitoring

    while true; do
        curl -s --raw -L "${prometheus_url}"     | grep Prometheus && \
        curl -s --raw -L "${grafana_url}"      | grep Grafana && \
        curl -s --raw -L "${alertmanager_url}" | grep Alertmanager && \
        echo "Monitoring URLs are all responding" && \
        break
        sleep 10
    done
}


get_opts ${@}

# Install deps
install_dependencies

# Install Prom
setup_prom_monitoring

# Install DCGM-Exporter and setup custom metrics, if needed
# # GPU Device Plugin is installed into kube-system, GPU Operator installs it into gpu-operator, use uniq for HA K8s clusters
plugin_namespace=$( kubectl get pods -A -l app.kubernetes.io/instance=nvidia-device-plugin  --no-headers   --no-headers -o custom-columns=NAMESPACE:.metadata.namespace | uniq)
if [ "${plugin_namespace}" == "kube-system" ] ; then
    # No GPU Operator DCGM-Exporter Stack
    setup_gpu_monitoring
fi

# Install custom gpu dashboards
setup_gpu_monitoring_dashboard

# Print URL outputs
print_monitoring
