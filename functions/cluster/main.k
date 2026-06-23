
import models.io.upbound.platform.aws.v1alpha1 as awsplatformv1alpha1
import models.io.upbound.platform.observe.v1alpha1 as observev1alpha1
import models.io.upbound.platform.gitops.v1alpha1 as gitopsv1alpha1

oxr = option("params").oxr
_ocds = option("params").ocds
_dxr = option("params").dxr
dcds = option("params").dcds

params = oxr.spec.parameters
uid = oxr.metadata?.uid

# reclaimPolicy (PV vocabulary) -> Crossplane management policies, for the
# function-encapsulated v2 children (Oss/Flux) that still take them directly.
_reclaimPolicy = params?.reclaimPolicy or "Delete"
_managementPolicies = ["Create", "Observe", "Update", "LateInitialize"] if _reclaimPolicy == "Retain" else ["*"]
_providerConfigName = params?.overrides?.providerConfigName or "default"

# Operator chart versions are an implementation detail (Observability/GitOps are
# function-encapsulated); the platform sets defaults, power users may override.
_operatorDefaults = {
    flux = {version = "2.10.6"}
    fluxSync = {version = "1.7.2"}
    prometheus = {version = "52.1.0"}
}
_operators = _operatorDefaults | (params?.overrides?.operators or {})

# The consumer supplies only the GitOps source (url/ref/path); the platform owns
# the GitRepository tuning (interval/timeout).
_gitopsSource = {
    git = {
        interval = "5m0s"
        timeout = "60s"
        url = params.gitops.git.url
        path = params?.gitops?.git?.path or "/"
        ref = params.gitops.git.ref
    }
}

_defaults = {
    managementPolicies = _managementPolicies
    providerConfigName = _providerConfigName
}

_metadata = lambda name: str -> any {
    { annotations = { "krm.kcl.dev/composition-resource-name" = name }}
}

# Connection secret name
connectionSecretName = params.id + "-eks"

# Inter-domain contract: read the composed Network XR's published status
# (networkId + AZ-structured zones[]) and inject resolved placement into the
# children. Parent-injection mechanism — Network.status is the single source of
# truth; no provider-MR label coupling, no leaked vpcId field.
_net = _ocds?["Network"]?.Resource?.status or {}
_networkId = _net?.networkId
_zones = _net?.zones or []
_publicSubnetIds = [z.publicSubnetId for z in _zones if z?.publicSubnetId]
_privateSubnetIds = [z.privateSubnetId for z in _zones if z?.privateSubnetId]
# Readiness gate: Compute is not created until the Network has published its
# zones (the network wiring must exist before nodes land).
_networkReady = len(_zones) > 0

# nodes.size, reclaimPolicy, providerConfig, operators and the gitops source are
# now first-class L1 contract fields — passed through, no compatibility shims.

# Check if EKS is ready before creating any Helm releases (they all need kubeconfig)
_eksReadyCondition = [condition for condition in (_ocds?["EKS"]?.Resource?.status?.conditions or []) if condition.type == "Ready" and condition.status == "True"]
_isEksReady = len(_eksReadyCondition) > 0

# Check if AWSLBController already exists (safety check to prevent uninstalling)
_lbControllerExists = "AWSLBController" in _ocds

# Check if AWSLBController is ready before creating Flux and OSS (to avoid webhook conflicts)
_lbControllerReadyCondition = [condition for condition in (_ocds?["AWSLBController"]?.Resource?.status?.conditions or []) if condition.type == "Ready" and condition.status == "True"]
_isLbControllerReady = len(_lbControllerReadyCondition) > 0

# Check if dependent resources already exist (safety checks to prevent uninstalling)
_ossExists = "Oss" in _ocds
_fluxExists = "Flux" in _ocds

# Network topology (AZ count, CIDR, subnet strategy, NAT) is the Network
# domain's concern now — L1 passes only region and lets the v3 Network XRD
# apply its defaults. The old hardcoded region→AZ map and 192.168/18 subnet
# plan are gone; that is exactly the implementation detail L1 no longer owns.

_items = [
    # Network resource (v3 contract: intent only — region; topology defaults
    # live in the Network domain). No id/subnets, no Crossplane machinery.
    awsplatformv1alpha1.Network {
        metadata: _metadata("Network") | {
            name = params.id + "-network"
        }
        spec: {
            parameters: {
                region = params.region
                reclaimPolicy = _reclaimPolicy
                overrides = {
                    providerConfigName = _providerConfigName
                }
            }
        }
    }

    # Compute — created only once the Network has published its zones; subnet
    # placement is injected from Network.status (no MR-label selectors). L1's
    # legacy instanceType/iam/providerConfigName map onto the v3 Compute contract.
    if _networkReady:
        awsplatformv1alpha1.Compute {
            metadata: _metadata("EKS") | {
                name = params.id + "-eks"
                labels: {
                    "platform.upbound.io/deletion-ordering" = oxr.metadata?.labels?["platform.upbound.io/deletion-ordering"]
                }
                annotations: {
                    "crossplane.io/external-name" = params.id
                }
            }
            spec: {
                parameters: {
                    id = params.id
                    region = params.region
                    engine = "eks"
                    version = params.version
                    nodes = {
                        count = params.nodes.count
                        size = params.nodes.size
                    }
                    subnetIds = {
                        public = _publicSubnetIds
                        private = _privateSubnetIds
                    }
                    reclaimPolicy = _reclaimPolicy
                    overrides = {
                        providerConfigName = _providerConfigName
                    }
                    if params.adminPrincipals:
                        adminPrincipals = params.adminPrincipals
                }
            }
        }

    # Ingress — created once Compute is ready. It resolves the cluster's
    # connection config, vpc id and name from Compute's published status itself
    # (via computeRef), so L1 injects neither a ProviderConfig name nor a vpcId.
    if _isEksReady or _lbControllerExists:
        awsplatformv1alpha1.Ingress {
            metadata: _metadata("AWSLBController") | {
                name = params.id + "-lb-controller"
            }
            spec: {
                parameters: {
                    type = "alb"
                    region = params.region
                    computeRef = {
                        id = params.id + "-eks"
                    }
                    reclaimPolicy = _reclaimPolicy
                    overrides = {
                        providerConfigName = _providerConfigName
                    }
                }
            }
        }

    # Oss resource - only create when LB Controller is ready (to avoid webhook conflicts)
    # Also create if it already exists to prevent uninstalling
    if _isLbControllerReady or _ossExists:
        observev1alpha1.Oss {
            metadata: _metadata("Oss") | {
                name = params.id + "-oss"
            }
            spec: {
                parameters: {
                    id = params.id
                    operators: {
                        prometheus = _operators.prometheus
                    }
                    managementPolicies = _managementPolicies
                }
            }
        }

    # Flux resource - only create when LB Controller is ready (to avoid webhook conflicts)
    # Also create if it already exists to prevent uninstalling
    if _isLbControllerReady or _fluxExists:
        gitopsv1alpha1.Flux {
            metadata: _metadata("Flux") | {
                name = params.id + "-flux"
            }
            spec: {
                parameters: _defaults | {
                    providerConfigName = params.id
                    operators: {
                        flux = _operators.flux
                        fluxSync = _operators.fluxSync
                    }
                    source = _gitopsSource
                }
            }
        }

    # Usage resources for dependency management (untyped objects)
    {
        apiVersion: "protection.crossplane.io/v1beta1"
        kind: "Usage"
        metadata: _metadata("usageXNetworkByEKS") | {
            name = params.id + "-network-by-eks"
        }
        spec: {
            replayDeletion = True
            by: {
                apiVersion = "aws.platform.upbound.io/v1alpha1"
                kind = "Compute"
                resourceSelector: {
                    matchControllerRef = True
                }
            }
            of: {
                apiVersion = "aws.platform.upbound.io/v1alpha1"
                kind = "Network"
                resourceSelector: {
                    matchControllerRef = True
                }
            }
        }
    }

    {
        apiVersion: "protection.crossplane.io/v1beta1"
        kind: "Usage"
        metadata: _metadata("usageXEksByFlux") | {
            name = params.id + "-eks-by-flux"
        }
        spec: {
            replayDeletion = True
            by: {
                apiVersion = "gitops.platform.upbound.io/v1alpha1"
                kind = "Flux"
                resourceSelector: {
                    matchControllerRef = True
                }
            }
            of: {
                apiVersion = "aws.platform.upbound.io/v1alpha1"
                kind = "Compute"
                resourceSelector: {
                    matchControllerRef = True
                }
            }
        }
    }

    {
        apiVersion: "protection.crossplane.io/v1beta1"
        kind: "Usage"
        metadata: _metadata("usageXEksByOss") | {
            name = params.id + "-eks-by-oss"
        }
        spec: {
            replayDeletion = True
            by: {
                apiVersion = "observe.platform.upbound.io/v1alpha1"
                kind = "Oss"
                resourceSelector: {
                    matchControllerRef = True
                }
            }
            of: {
                apiVersion = "aws.platform.upbound.io/v1alpha1"
                kind = "Compute"
                resourceSelector: {
                    matchControllerRef = True
                }
            }
        }
    }
    
    {
        apiVersion: "protection.crossplane.io/v1beta1"
        kind: "Usage"
        metadata: _metadata("usageEksByArbitraryLabeledRelease") | {
            name = params.id + "-eks-by-labeled-release"
            annotations = {
                "krm.kcl.dev/ready": "True"
            }
        }
        spec: {
            replayDeletion = True
            by: {
                apiVersion = "helm.crossplane.io/v1beta1"
                kind = "Release"
                resourceSelector: {
                    matchLabels: {
                        "platform.upbound.io/deletion-ordering" = "enabled"
                    }
                }
            }
            of: {
                apiVersion = "aws.platform.upbound.io/v1alpha1"
                kind = "Compute"
                resourceSelector: {
                    matchControllerRef = True
                }
            }
        }
    }
    
    {
        apiVersion: "protection.crossplane.io/v1beta1"
        kind: "Usage"
        metadata: _metadata("usageAWSLBControllerByArbitraryLabeledApp") | {
            name = params.id + "-lb-controller-by-labeled-app"
            annotations = {
                "krm.kcl.dev/ready": "True"
            }
        }
        spec: {
            replayDeletion = True
            by: {
                apiVersion = "platform.upbound.io/v1alpha1"
                kind = "XApp"
                resourceSelector: {
                    matchLabels: {
                        "platform.upbound.io/deletion-ordering" = "enabled"
                    }
                }
            }
            of: {
                apiVersion = "aws.platform.upbound.io/v1alpha1"
                kind = "Ingress"
                resourceSelector: {
                    matchControllerRef = True
                }
            }
        }
    }
    
    # Usage resource to ensure Flux is deleted before AWSLBController
    {
        apiVersion: "protection.crossplane.io/v1beta1"
        kind: "Usage"
        metadata: _metadata("usageAWSLBControllerByFlux") | {
            name = params.id + "-lb-controller-by-flux"
            annotations = {
                "krm.kcl.dev/ready": "True"
            }
        }
        spec: {
            replayDeletion = True
            by: {
                apiVersion: "gitops.platform.upbound.io/v1alpha1"
                kind: "Flux"
                resourceSelector: {
                    matchControllerRef = True
                }
            }
            of: {
                apiVersion: "aws.platform.upbound.io/v1alpha1"
                kind: "Ingress"
                resourceSelector: {
                    matchControllerRef = True
                }
            }
        }
    }

    # Forward connection details from EKS
    {
        apiVersion: "meta.krm.kcl.dev/v1alpha1"
        kind: "CompositeConnectionDetails"
        if "EKS" in _ocds:
            data: {
                kubeconfig = _ocds["EKS"].ConnectionDetails.kubeconfig
            }
        else:
            data: {}
    }
]

# Publish a clean status (cluster name from the Compute child).
_dxr = _dxr | {
    status: {
        if _ocds?["EKS"]?.Resource?.status?.clusterName:
            clusterName = _ocds["EKS"].Resource.status.clusterName
    }
}
_items += [_dxr]

items = _items
