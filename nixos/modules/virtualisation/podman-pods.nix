{ lib, config, options, ... }:

with lib;

let
  cfg = config.virtualisation.podman-pods;
  list-to-args = arg: list:
    concatStringsSep " " (map (e: "--${arg}=${escapeShellArg e}") list);
  possibly-unset-arg = arg: val:
    (optionalString (val != null) "--${arg}=${escapeShellArg val}");

  mkPod = name: pod: rec {
    path = [ config.virtualisation.podman.package ];

    wants = [ "network.target" ];
    after = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" "default.target" ];

    environment.PODMAN_SYSTEMD_UNIT = "%n";

    preStart = concatStringsSep " " [
      "mkdir -p /run/podman/pods/ ;"
      "podman pod create"
      "--infra-conmon-pidfile=${escapeShellArg "/run/podman/pods/${name}.pid"}"
      "--name=${escapeShellArg name}"
      "--replace"
      (list-to-args "add-host" pod.added-hosts)
      (possibly-unset-arg "cgroup-parent" pod.cgroup-parent)
      (list-to-args "dns" pod.dns)
      (list-to-args "dns-opt" pod.dns-opt)
      (list-to-args "dns-search" pod.dns-search)
      (possibly-unset-arg "hostname" pod.hostname)
      (possibly-unset-arg "infra" pod.infra)
      (possibly-unset-arg "infra-command" pod.infra-command)
      (possibly-unset-arg "infra-image" pod.infra-image)
      (possibly-unset-arg "ip" pod.ip)
      (possibly-unset-arg "mac-address" pod.mac-address)
      (possibly-unset-arg "network" pod.network)
      (possibly-unset-arg "network-alias" pod.network-alias)
      (possibly-unset-arg "no-hosts" pod.no-hosts)
      (list-to-args "publish" pod.publish)
      (list-to-args "share" pod.share)
    ];

    script = "podman pod start ${escapeShellArg name}";
    preStop = "podman pod stop ${escapeShellArg name}";
    # `podman generate systemd` generates a second stop after the
    # first; not sure why but clearly it's recommended.
    postStop = preStop;

    serviceConfig = rec {
      Type = "forking";
      TimeoutStopSec = 70;
      Restart = "on-failure";
      PIDFile = "/run/podman/pods/${name}.pid";
    };
  };

in {
  options.virtualisation.podman-pods = mkOption {
    type = with types;
      attrsOf (submodule {
        options = {
          added-hosts = mkOption {
            type = listOf str;
            default = [ ];
            description =
              "Additional hosts to add to /etc/hosts for each container.";
            example = literalExample ''
              [ "database:10.0.0.1" ]
            '';
          };

          cgroup-parent = mkOption {
            type = nullOr str;
            default = null;
            description =
              "The cgroups path under which the pod cgroup will be created.";
          };

          dns = mkOption {
            type = listOf str;
            default = [ ];
            description = "The dns servers to set in /etc/resolv.conf.";
          };

          dns-opt = mkOption {
            type = listOf str;
            default = [ ];
            description = "dns options to set in /etc/resolv.conf.";
          };

          dns-search = mkOption {
            type = listOf str;
            default = [ ];
            description = "Search domains to set in /etc/resolv.conf.";
          };

          hostname = mkOption {
            type = nullOr str;
            default = null;
            description = "The pod hostname.";
          };

          infra = mkOption {
            type = nullOr bool;
            default = null;
            description = "Whether to create the infra container for the pod.";
          };

          infra-command = mkOption {
            type = nullOr str;
            default = null;
            description = "The command to run in the infra container.";
          };

          infra-image = mkOption {
            type = nullOr str;
            default = null;
            description = "The image to use for the infra container.";
          };

          ip = mkOption {
            type = nullOr str;
            default = null;
            description = "A static IP address for the pod network.";
          };

          # TODO: set up label file stuff.
          #
          # labels = mkOption {};

          mac-address = mkOption {
            type = nullOr str;
            default = null;
            description = "A static mac address for the pod network.";
          };

          network = mkOption {
            type = nullOr str;
            default = null;
            description = "Network configuration for the pod.";
          };

          network-alias = mkOption {
            type = nullOr str;
            default = null;
            description = "DNS alias for the pod.";
          };

          no-hosts = mkOption {
            type = nullOr bool;
            default = null;
            description = "Whether to disable /etc/hosts creation for the pod.";
          };

          publish = mkOption {
            type = listOf str;
            default = [ ];
            description = "List of ports to publish from the pod.";
          };

          share = mkOption {
            type = listOf str;
            default = [ ];
            description = "List of kernel namespaces to share.";
          };

          containers = options.virtualisation.oci-containers.containers;
        };
      });
    default = { };
    description = "Podman pods to run as systemd services.";
  };

  config = let
    # Merge a list of attribute sets together
    #
    # TODO: See if there's a generic version for this somewhere in the
    # pkgs lib?
    mergeAttrs = attrList: foldr (a: b: a // b) { } attrList;

    # Create services for all defined pods
    pod-services = mapAttrs' (n: v: nameValuePair "pod-${n}" (mkPod n v)) cfg;

    # Override the systemd-specific settings of containers defined in
    # pods.
    #
    # I.e., make a systemd unit dependency on the pod service.
    pod-container-services = mergeAttrs (mapAttrsToList (pname: pod:
      mapAttrs' (cname: container:
        nameValuePair "podman-${pname}-${cname}" rec {
          after = [ "pod-${pname}.service" ];
          requires = after;
        }) pod.containers) cfg);

    # Override the oci-container settings for containers defined in pods.
    #
    # I.e., set the --pod=podname setting, and update the dependsOn so
    # it points to containers in the same pod.
    podifyContainer = container: podname:
      container // {
        dependsOn =
          map (dependency: "${podname}-${dependency}") container.dependsOn;
        extraOptions = container.extraOptions ++ [ "--pod=${podname}" ];
      };

  in lib.mkIf (cfg != { }) {
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    systemd.services = pod-services // pod-container-services;

    virtualisation.oci-containers.containers = mergeAttrs (mapAttrsToList
      (pname: pod:
        mapAttrs' (cname: container:
          nameValuePair "${pname}-${cname}" (podifyContainer container pname))
        pod.containers) cfg);
  };
}
