#!/bin/bash
set -e

echo "==> 1. Instalando o operador OpenShift GitOps..."
oc apply -f 01-namespace.yaml
oc apply -f 02-operatorgroup.yaml
oc apply -f 03-subscription.yaml

echo ""
echo "==> 2. Aguardando o CSV ficar Succeeded (pode levar ~2 min)..."
until oc get csv -n openshift-gitops-operator \
  -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift GitOps")].status.phase}' \
  2>/dev/null | grep -q "Succeeded"; do
  echo "   Aguardando CSV..."
  sleep 15
done
echo "   CSV Succeeded!"

echo ""
echo "==> 3. Aguardando namespace openshift-gitops ser criado automaticamente..."
until oc get namespace openshift-gitops &>/dev/null; do
  echo "   Aguardando namespace..."
  sleep 5
done
echo "   Namespace criado!"

echo ""
echo "==> 4. Aplicando instância do ArgoCD customizada..."
oc apply -f 04-argocd-instance.yaml

echo ""
echo "==> 5. Aguardando ArgoCD ficar disponível..."
until oc get argocd openshift-gitops -n openshift-gitops \
  -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Available"; do
  echo "   Aguardando ArgoCD..."
  sleep 15
done
echo "   ArgoCD disponível!"

echo ""
echo "==> 6. URL de acesso:"
oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='https://{.spec.host}{"\n"}'

echo ""
echo "==> 7. Senha inicial do admin (se SSO não funcionar):"
oc get secret openshift-gitops-cluster -n openshift-gitops \
  -o jsonpath='{.data.admin\.password}' | base64 -d
echo ""

echo ""
echo "Instalação concluída!"
echo "Login: use sua conta do OpenShift via SSO (OAuth) ou admin + senha acima."
