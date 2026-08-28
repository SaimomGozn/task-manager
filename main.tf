terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

resource "null_resource" "k3d_cluster" {
  provisioner "local-exec" {
    command = "k3d cluster create obsv-cluster --servers 1 --agents 0 --k3s-arg --disable=traefik@server:0 --wait"
  }
  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete obsv-cluster"
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
  depends_on = [null_resource.k3d_cluster]
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 600

  set {
    name  = "alertmanager.enabled"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "grafana.resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "grafana.resources.requests.memory"
    value = "64Mi"
  }

  depends_on = [null_resource.k3d_cluster]
}

resource "helm_release" "loki_stack" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 600

  set {
    name  = "promtail.enabled"
    value = "true"
  }
  set {
    name  = "loki.isDefault"
    value = "false"
  }
  set {
    name  = "loki.persistence.enabled"
    value = "false"
  }

  depends_on = [null_resource.k3d_cluster]
}

resource "kubernetes_deployment" "task_manager" {
  metadata {
    name      = "task-manager"
    namespace = "default"
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "task-manager"
      }
    }
    template {
      metadata {
        labels = {
          app = "task-manager"
        }
      }
      spec {
        container {
          image             = "task-manager:latest"
          name              = "task-manager"
          image_pull_policy = "IfNotPresent"
          port {
            container_port = 3000
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
          }
        }
      }
    }
  }
  depends_on = [null_resource.k3d_cluster]
}

resource "kubernetes_service" "task_manager" {
  metadata {
    name      = "task-manager"
    namespace = "default"
  }
  spec {
    selector = {
      app = "task-manager"
    }
    port {
      port        = 80
      target_port = 3000
    }
    type = "ClusterIP"
  }
  depends_on = [kubernetes_deployment.task_manager]
}