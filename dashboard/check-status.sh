#!/bin/bash

# Script to check the status of all Kubeflow Dashboard components deployed by minimal-deploy.sh
# Usage: ./check-status.sh [namespace]
# Default namespace: kubeflow

NAMESPACE="${1:-kubeflow}"

echo "========================================="
echo "Kubeflow Dashboard Component Status"
echo "Namespace: ${NAMESPACE}"
echo "========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print section header
print_section() {
  echo -e "${BLUE}=== $1 ===${NC}"
}

# Function to print component header
print_component() {
  echo -e "${GREEN}--- $1 ---${NC}"
}

# 1. Profile Controller & Access Management (KFAM) Components
print_section "Profile Controller & Access Management (KFAM)"
print_component "Deployments"
kubectl get deployments -n "${NAMESPACE}" -l kustomize.component=profiles

print_component "Pods"
kubectl get pods -n "${NAMESPACE}" -l kustomize.component=profiles

print_component "Services"
kubectl get services -n "${NAMESPACE}" -l kustomize.component=profiles

print_component "ServiceAccounts"
kubectl get serviceaccounts -n "${NAMESPACE}" -l kustomize.component=profiles

print_component "RBAC (ClusterRoles & ClusterRoleBindings)"
kubectl get clusterroles -l kustomize.component=profiles
kubectl get clusterrolebindings -l kustomize.component=profiles

print_component "Roles & RoleBindings (if any)"
kubectl get roles -n "${NAMESPACE}" -l kustomize.component=profiles 2>/dev/null || echo "No Roles found"
kubectl get rolebindings -n "${NAMESPACE}" -l kustomize.component=profiles 2>/dev/null || echo "No RoleBindings found"

print_component "ConfigMaps (if any)"
kubectl get configmaps -n "${NAMESPACE}" -l kustomize.component=profiles 2>/dev/null || echo "No ConfigMaps found"

echo ""

# 2. Poddefaults Webhooks Components
print_section "Poddefaults Webhooks"
print_component "Deployments"
kubectl get deployments -n "${NAMESPACE}" -l app=poddefaults

print_component "Pods"
kubectl get pods -n "${NAMESPACE}" -l app=poddefaults

print_component "Services"
kubectl get services -n "${NAMESPACE}" -l app=poddefaults

print_component "ServiceAccounts"
kubectl get serviceaccounts -n "${NAMESPACE}" -l app=poddefaults

print_component "MutatingWebhookConfiguration"
kubectl get mutatingwebhookconfiguration -l app=poddefaults

print_component "RBAC (ClusterRoles & ClusterRoleBindings)"
kubectl get clusterroles -l app=poddefaults
kubectl get clusterrolebindings -l app=poddefaults

print_component "Certificates (cert-manager)"
kubectl get certificates -n "${NAMESPACE}" -l app=poddefaults

print_component "Certificate Issuers (cert-manager)"
kubectl get issuers -n "${NAMESPACE}" -l app=poddefaults

print_component "Secrets (created by cert-manager)"
kubectl get secrets -n "${NAMESPACE}" | grep -E "(poddefaults|webhook.*cert)" || echo "No matching secrets found"

print_component "Roles & RoleBindings (if any)"
kubectl get roles -n "${NAMESPACE}" -l app=poddefaults 2>/dev/null || echo "No Roles found"
kubectl get rolebindings -n "${NAMESPACE}" -l app=poddefaults 2>/dev/null || echo "No RoleBindings found"

print_component "ConfigMaps (if any)"
kubectl get configmaps -n "${NAMESPACE}" -l app=poddefaults 2>/dev/null || echo "No ConfigMaps found"

echo ""

# 3. Central Dashboard Components
print_section "Central Dashboard"
print_component "Deployments"
kubectl get deployments -n "${NAMESPACE}" | grep -E "(centraldashboard|dashboard)" || kubectl get deployments -n "${NAMESPACE}" -l app=centraldashboard 2>/dev/null || echo "No deployments found"

print_component "Pods"
kubectl get pods -n "${NAMESPACE}" | grep -E "(centraldashboard|dashboard)" || kubectl get pods -n "${NAMESPACE}" -l app=centraldashboard 2>/dev/null || echo "No pods found"

print_component "Services"
kubectl get services -n "${NAMESPACE}" | grep -E "(centraldashboard|dashboard)" || kubectl get services -n "${NAMESPACE}" -l app=centraldashboard 2>/dev/null || echo "No services found"

print_component "ServiceAccounts"
kubectl get serviceaccounts -n "${NAMESPACE}" | grep -E "(centraldashboard|dashboard)" || kubectl get serviceaccounts -n "${NAMESPACE}" -l app=centraldashboard 2>/dev/null || echo "No serviceaccounts found"

print_component "RBAC Resources"
kubectl get clusterroles | grep -E "(centraldashboard|dashboard)" || echo "No ClusterRoles found"
kubectl get clusterrolebindings | grep -E "(centraldashboard|dashboard)" || echo "No ClusterRoleBindings found"
kubectl get roles -n "${NAMESPACE}" | grep -E "(centraldashboard|dashboard)" 2>/dev/null || echo "No Roles found"
kubectl get rolebindings -n "${NAMESPACE}" | grep -E "(centraldashboard|dashboard)" 2>/dev/null || echo "No RoleBindings found"

print_component "ConfigMaps (if any)"
kubectl get configmaps -n "${NAMESPACE}" | grep -E "(centraldashboard|dashboard)" 2>/dev/null || echo "No ConfigMaps found"

echo ""

# 3b. Central Dashboard Angular Components
print_section "Central Dashboard Angular"
print_component "Deployments"
kubectl get deployments -n "${NAMESPACE}" | grep -E "(angular|centraldashboard-angular)" || echo "No deployments found"

print_component "Pods"
kubectl get pods -n "${NAMESPACE}" | grep -E "(angular|centraldashboard-angular)" || echo "No pods found"

print_component "Services"
kubectl get services -n "${NAMESPACE}" | grep -E "(angular|centraldashboard-angular)" || echo "No services found"

print_component "ServiceAccounts"
kubectl get serviceaccounts -n "${NAMESPACE}" | grep -E "(angular|centraldashboard-angular)" || echo "No serviceaccounts found"

print_component "RBAC Resources"
kubectl get clusterroles | grep -E "(angular|centraldashboard-angular)" || echo "No ClusterRoles found"
kubectl get clusterrolebindings | grep -E "(angular|centraldashboard-angular)" || echo "No ClusterRoleBindings found"
kubectl get roles -n "${NAMESPACE}" | grep -E "(angular|centraldashboard-angular)" 2>/dev/null || echo "No Roles found"
kubectl get rolebindings -n "${NAMESPACE}" | grep -E "(angular|centraldashboard-angular)" 2>/dev/null || echo "No RoleBindings found"

print_component "ConfigMaps (if any)"
kubectl get configmaps -n "${NAMESPACE}" | grep -E "(angular|centraldashboard-angular)" 2>/dev/null || echo "No ConfigMaps found"

echo ""

# 4. Custom Resource Definitions (CRDs)
print_section "Custom Resource Definitions (CRDs)"
print_component "All Kubeflow CRDs"
kubectl get crds | grep -E "(kubeflow\.org|profiles|poddefaults)" || echo "No matching CRDs found"

print_component "Specific CRD Status"
kubectl get crd profiles.kubeflow.org 2>/dev/null && echo "✓ profiles.kubeflow.org CRD exists" || echo "✗ profiles.kubeflow.org CRD not found (may be commented out)"
kubectl get crd poddefaults.kubeflow.org 2>/dev/null && echo "✓ poddefaults.kubeflow.org CRD exists" || echo "✗ poddefaults.kubeflow.org CRD not found"

echo ""

# 5. All Resources in Kubeflow Namespace (Summary View)
print_section "All Resources Summary in ${NAMESPACE} Namespace"
print_component "All Workloads"
kubectl get all -n "${NAMESPACE}"

echo ""

print_component "All Deployments (Detailed)"
kubectl get deployments -n "${NAMESPACE}" -o wide

echo ""

print_component "All Pods (Detailed)"
kubectl get pods -n "${NAMESPACE}" -o wide

echo ""

print_component "All Services"
kubectl get services -n "${NAMESPACE}"

echo ""

print_component "All ServiceAccounts"
kubectl get serviceaccounts -n "${NAMESPACE}"

echo ""

print_component "All Secrets"
kubectl get secrets -n "${NAMESPACE}" | grep -E "(profile|poddefault|dashboard|cert|webhook)" || echo "No matching secrets found"

echo ""

print_component "All ConfigMaps"
kubectl get configmaps -n "${NAMESPACE}" | grep -E "(profile|poddefault|dashboard|central)" || echo "No matching configmaps found"

echo ""

print_component "All Roles & RoleBindings"
kubectl get roles -n "${NAMESPACE}" 2>/dev/null | grep -v "^NAME" && echo "" || echo "No Roles found in namespace"
kubectl get rolebindings -n "${NAMESPACE}" 2>/dev/null | grep -v "^NAME" && echo "" || echo "No RoleBindings found in namespace"

echo ""

# 6. Health Check - Pod Status Summary
print_section "Health Check - Pod Status"
echo "Checking pod readiness..."
NOT_READY=$(kubectl get pods -n "${NAMESPACE}" --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l)
if [ "${NOT_READY}" -eq 0 ]; then
  echo -e "${GREEN}✓ All pods are running or completed${NC}"
else
  echo -e "${YELLOW}⚠ Some pods are not in Running/Succeeded state:${NC}"
  kubectl get pods -n "${NAMESPACE}" --field-selector=status.phase!=Running,status.phase!=Succeeded
fi

echo ""
echo "Checking pod restart counts..."
kubectl get pods -n "${NAMESPACE}" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp

echo ""

# 7. Event Logs (Recent Issues)
print_section "Recent Events"
kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -20

echo ""
echo "========================================="
echo "Status check complete!"
echo "========================================="

