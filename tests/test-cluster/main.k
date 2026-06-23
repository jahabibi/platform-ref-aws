
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as awsplatformv1alpha1
import models.io.upbound.platform.observe.v1alpha1 as observev1alpha1
import models.io.upbound.platform.gitops.v1alpha1 as gitopsv1alpha1
import models.io.upbound.platformref.aws.v1alpha1 as platformrefawsv1alpha1

_items = [
    metav1alpha1.CompositionTest{
        metadata.name: "test-cluster"
        spec = {
            assertResources: [
                # Cluster for main composite resource
                platformrefawsv1alpha1.Cluster{
                    metadata.name: "platform-ref-aws"
                    spec = {
                        parameters = {
                            id: "platform-ref-aws"
                            region: "us-west-2"
                            version: "1.32"
                            nodes = {
                                count: 3
                                size: "small"
                            }
                            gitops = {
                                git = {
                                    url: "https://github.com/upbound/platform-ref-aws/"
                                    path: "/"
                                    ref = {
                                        name: "refs/heads/main"
                                    }
                                }
                            }
                        }
                    }
                }
                # Network for AWS networking (v3 contract: region + overrides only)
                awsplatformv1alpha1.Network{
                    metadata.name: "platform-ref-aws-network"
                    spec = {
                        parameters = {
                            region: "us-west-2"
                            overrides = {
                                providerConfigName: "default"
                            }
                        }
                    }
                },
                # Compute (Amazon EKS engine)
                awsplatformv1alpha1.Compute{
                    metadata = {
                        name: "platform-ref-aws-eks"
                        labels = {
                            "platform.upbound.io/deletion-ordering": "enabled"
                        }
                        annotations = {
                            "crossplane.io/external-name": "platform-ref-aws"
                        }
                    }
                    spec = {
                        parameters = {
                            id: "platform-ref-aws"
                            region: "us-west-2"
                            engine: "eks"
                            version: "1.32"
                            nodes = {
                                count: 3
                                size: "small"
                            }
                            # injected from Network.status.zones[] by the L1 function
                            subnetIds = {
                                public = ["subnet-pub-a", "subnet-pub-b"]
                                private = ["subnet-priv-a", "subnet-priv-b"]
                            }
                            overrides = {
                                providerConfigName: "default"
                            }
                        }
                    }
                },
                # Oss for observability stack
                observev1alpha1.Oss{
                    metadata.name: "platform-ref-aws-oss"
                    spec = {
                        parameters = {
                            managementPolicies: ["*"]
                            id: "platform-ref-aws"
                            operators = {
                                prometheus = {
                                    version: "52.1.0"
                                }
                            }
                        }
                    }
                },
                # Flux for GitOps
                gitopsv1alpha1.Flux{
                    metadata.name: "platform-ref-aws-flux"
                    spec = {
                        parameters = {
                            managementPolicies: ["*"]
                            providerConfigName: "platform-ref-aws"
                            operators = {
                                flux = {
                                    version: "2.10.6"
                                }
                                fluxSync = {
                                    version: "1.7.2"
                                }
                            }
                            source = {
                                git = {
                                    interval: "5m0s"
                                    timeout: "60s"
                                    url: "https://github.com/upbound/platform-ref-aws/"
                                    path: "/"
                                    ref = {
                                        name: "refs/heads/main"
                                    }
                                }
                            }
                        }
                    }
                },
                # Ingress (ALB) for Load Balancer Controller
                awsplatformv1alpha1.Ingress{
                    metadata.name: "platform-ref-aws-lb-controller"
                    spec = {
                        parameters = {
                            type: "alb"
                            region: "us-west-2"
                            computeRef = {
                                id: "platform-ref-aws-eks"
                            }
                            overrides = {
                                providerConfigName: "default"
                            }
                        }
                    }
                },
                # Usage resources for dependency management (untyped objects)
                {
                    apiVersion: "protection.crossplane.io/v1beta1"
                    kind: "Usage"
                    metadata.name: "platform-ref-aws-network-by-eks"
                    spec = {
                        replayDeletion: True
                        by = {
                            apiVersion: "aws.platform.upbound.io/v1alpha1"
                            kind: "Compute"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                        of = {
                            apiVersion: "aws.platform.upbound.io/v1alpha1"
                            kind: "Network"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                    }
                },
                {
                    apiVersion: "protection.crossplane.io/v1beta1"
                    kind: "Usage"
                    metadata.name: "platform-ref-aws-eks-by-flux"
                    spec = {
                        replayDeletion: True
                        by = {
                            apiVersion: "gitops.platform.upbound.io/v1alpha1"
                            kind: "Flux"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                        of = {
                            apiVersion: "aws.platform.upbound.io/v1alpha1"
                            kind: "Compute"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                    }
                },
                {
                    apiVersion: "protection.crossplane.io/v1beta1"
                    kind: "Usage"
                    metadata.name: "platform-ref-aws-eks-by-oss"
                    spec = {
                        replayDeletion: True
                        by = {
                            apiVersion: "observe.platform.upbound.io/v1alpha1"
                            kind: "Oss"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                        of = {
                            apiVersion: "aws.platform.upbound.io/v1alpha1"
                            kind: "Compute"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                    }
                },
                {
                    apiVersion: "protection.crossplane.io/v1beta1"
                    kind: "Usage"
                    metadata.name: "platform-ref-aws-eks-by-labeled-release"
                    spec = {
                        replayDeletion: True
                        by = {
                            apiVersion: "helm.crossplane.io/v1beta1"
                            kind: "Release"
                            resourceSelector = {
                                matchLabels = {
                                    "platform.upbound.io/deletion-ordering": "enabled"
                                }
                            }
                        }
                        of = {
                            apiVersion: "aws.platform.upbound.io/v1alpha1"
                            kind: "Compute"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                    }
                },
                {
                    apiVersion: "protection.crossplane.io/v1beta1"
                    kind: "Usage"
                    metadata.name: "platform-ref-aws-lb-controller-by-labeled-app"
                    spec = {
                        replayDeletion: True
                        by = {
                            apiVersion: "platform.upbound.io/v1alpha1"
                            kind: "XApp"
                            resourceSelector = {
                                matchLabels = {
                                    "platform.upbound.io/deletion-ordering": "enabled"
                                }
                            }
                        }
                        of = {
                            apiVersion: "aws.platform.upbound.io/v1alpha1"
                            kind: "Ingress"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                    }
                },
                {
                    apiVersion: "protection.crossplane.io/v1beta1"
                    kind: "Usage"
                    metadata.name: "platform-ref-aws-lb-controller-by-flux"
                    spec = {
                        replayDeletion: True
                        by = {
                            apiVersion: "gitops.platform.upbound.io/v1alpha1"
                            kind: "Flux"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                        of = {
                            apiVersion: "aws.platform.upbound.io/v1alpha1"
                            kind: "Ingress"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                    }
                }
            ]
            observedResources: [
                # Network with v3 published status — the inter-domain contract the
                # L1 function reads (networkId + AZ-structured zones[]).
                awsplatformv1alpha1.Network{
                    metadata = {
                        name: "platform-ref-aws-network"
                        annotations = {
                            "crossplane.io/composition-resource-name" = "Network"
                        }
                    }
                    spec = {
                        parameters = {
                            region: "us-west-2"
                            overrides = {
                                providerConfigName: "default"
                            }
                        }
                    }
                    status = {
                        networkId: "vpc-0wired"
                        securityGroupId: "sg-0wired"
                        zones = [
                            {
                                name = "us-west-2a"
                                publicSubnetId = "subnet-pub-a"
                                privateSubnetId = "subnet-priv-a"
                                natGatewayId = "nat-a"
                            }
                            {
                                name = "us-west-2b"
                                publicSubnetId = "subnet-pub-b"
                                privateSubnetId = "subnet-priv-b"
                                natGatewayId = "nat-b"
                            }
                        ]
                    }
                },
                # Flux with Ready condition to trigger AWSLBController creation
                gitopsv1alpha1.Flux{
                    metadata = {
                        name: "platform-ref-aws-flux"
                        annotations = {
                            "crossplane.io/composition-resource-name" = "Flux"
                        }
                    }
                    spec = {
                        parameters = {
                            managementPolicies: ["*"]
                            providerConfigName: "platform-ref-aws"
                            operators = {
                                flux = {
                                    version: "2.10.6"
                                }
                                fluxSync = {
                                    version: "1.7.2"
                                }
                            }
                            source = {
                                git = {
                                    interval: "5m0s"
                                    timeout: "60s"
                                    url: "https://github.com/upbound/platform-ref-aws/"
                                    path: "/"
                                    ref = {
                                        name: "refs/heads/main"
                                    }
                                }
                            }
                        }
                    }
                    status = {
                        conditions = [
                            {
                                type = "Ready"
                                status = "True"
                                reason = "Available"
                                lastTransitionTime = "2025-08-13T22:30:00Z"
                            }
                        ]
                    }
                },
                # Compute with Ready condition to trigger Ingress creation
                awsplatformv1alpha1.Compute{
                    metadata = {
                        name: "platform-ref-aws-eks"
                        annotations = {
                            "crossplane.io/composition-resource-name" = "EKS"
                        }
                    }
                    spec = {
                        parameters = {
                            id: "platform-ref-aws"
                            region: "us-west-2"
                            engine: "eks"
                            version: "1.32"
                            nodes = {
                                count: 3
                                size: "small"
                            }
                        }
                    }
                    status = {
                        conditions = [
                            {
                                type = "Ready"
                                status = "True"
                                reason = "Available"
                                lastTransitionTime = "2025-08-13T23:00:00Z"
                            }
                        ]
                        clusterName: "platform-ref-aws-cluster"
                    }
                },
                # Ingress with Ready condition to trigger Flux and OSS creation
                awsplatformv1alpha1.Ingress{
                    metadata = {
                        name: "platform-ref-aws-lb-controller"
                        annotations = {
                            "crossplane.io/composition-resource-name" = "AWSLBController"
                        }
                    }
                    spec = {
                        parameters = {
                            type: "alb"
                            region: "us-west-2"
                            computeRef = {
                                id: "platform-ref-aws-eks"
                            }
                        }
                    }
                    status = {
                        conditions = [
                            {
                                type = "Ready"
                                status = "True"
                                reason = "Available"
                                lastTransitionTime = "2025-08-13T23:15:00Z"
                            }
                        ]
                    }
                }
            ]
            compositionPath: "apis/clusters/composition.yaml"
            xrPath: "examples/cluster-xr.yaml"
            xrdPath: "apis/clusters/definition.yaml"
            timeoutSeconds: 120
            validate: False
        }
    }
]
items = _items
