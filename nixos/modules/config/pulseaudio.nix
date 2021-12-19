{ config, lib, pkgs, ... }:

with pkgs;
with lib;

let

  cfg = config.hardware.pulseaudio;
  alsaCfg = config.sound;

  systemWide = cfg.enable && cfg.systemWide;
  nonSystemWide = cfg.enable && !cfg.systemWide;
  hasZeroconf = let z = cfg.zeroconf; in z.publish.enable || z.discovery.enable;

  overriddenPackage = cfg.package.override
    (optionalAttrs hasZeroconf { zeroconfSupport = true; });
  binary = "${getBin overriddenPackage}/bin/pulseaudio";
  binaryNoDaemon = "${binary} --daemonize=no";

  # Forces 32bit pulseaudio and alsa-plugins to be built/supported for apps
  # using 32bit alsa on 64bit linux.
  enable32BitAlsaPlugins = cfg.support32Bit && stdenv.isx86_64 && (pkgs.pkgsi686Linux.alsa-lib != null && pkgs.pkgsi686Linux.libpulseaudio != null);


  myConfigFile =
    let
      addModuleIf = cond: mod: optionalString cond "load-module ${mod}";
      allAnon = optional cfg.tcp.anonymousClients.allowAll "auth-anonymous=1";
      ipAnon =  let a = cfg.tcp.anonymousClients.allowedIpRanges;
                in optional (a != []) ''auth-ip-acl=${concatStringsSep ";" a}'';
      port = optional (cfg.tcp.port != null) "port=${toString cfg.tcp.port}";
    in writeTextFile {
      name = "default.pa";
        text = ''
        .include ${cfg.configFile}
        ${addModuleIf cfg.zeroconf.publish.enable "module-zeroconf-publish"}
        ${addModuleIf cfg.zeroconf.discovery.enable "module-zeroconf-discover"}
        ${addModuleIf cfg.tcp.enable (concatStringsSep " "
           ([ "module-native-protocol-tcp" ] ++ allAnon ++ ipAnon ++ port))}
        ${addModuleIf config.services.jack.jackd.enable "module-jack-sink"}
        ${addModuleIf config.services.jack.jackd.enable "module-jack-source"}
        ${cfg.extraConfig}
      '';
    };

  ids = config.ids;

  uid = ids.uids.pulseaudio;
  gid = ids.gids.pulseaudio;

  stateDir = "/run/pulse";

  # Create pulse/client.conf even if PulseAudio is disabled so
  # that we can disable the autospawn feature in programs that
  # are built with PulseAudio support (like KDE).
  clientConf = writeText "client.conf" ''
    autospawn=no
    ${cfg.extraClientConf}
  '';

  # Write an /etc/asound.conf that causes all ALSA applications to
  # be re-routed to the PulseAudio server through ALSA's Pulse
  # plugin.
  alsaConf = writeText "asound.conf" (''
    pcm_type.pulse {
      libs.native = ${pkgs.alsa-plugins}/lib/alsa-lib/libasound_module_pcm_pulse.so ;
      ${lib.optionalString enable32BitAlsaPlugins
     "libs.32Bit = ${pkgs.pkgsi686Linux.alsa-plugins}/lib/alsa-lib/libasound_module_pcm_pulse.so ;"}
    }
    pcm.!default {
      type pulse
      hint.description "Default Audio Device (via PulseAudio)"
    }
    ctl_type.pulse {
      libs.native = ${pkgs.alsa-plugins}/lib/alsa-lib/libasound_module_ctl_pulse.so ;
      ${lib.optionalString enable32BitAlsaPlugins
     "libs.32Bit = ${pkgs.pkgsi686Linux.alsa-plugins}/lib/alsa-lib/libasound_module_ctl_pulse.so ;"}
    }
    ctl.!default {
      type pulse
    }
    ${alsaCfg.extraConfig}
  '');

in {

  options = {

    hardware.pulseaudio = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable the PulseAudio sound server.
        '';
      };

      systemWide = mkOption {
        type = types.bool;
        default = false;
        description = ''
          If false, a PulseAudio server is launched automatically for
          each user that tries to use the sound system. The server runs
          with user privileges. If true, one system-wide PulseAudio
          server is launched on boot, running as the user "pulse", and
          only users in the "audio" group will have access to the server.
          Please read the PulseAudio documentation for more details.

          Don't enable this option unless you know what you are doing.
        '';
      };

      support32Bit = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to include the 32-bit pulseaudio libraries in the system or not.
          This is only useful on 64-bit systems and currently limited to x86_64-linux.
        '';
      };

      configFile = mkOption {
        type = types.nullOr types.path;
        description = ''
          The path to the default configuration options the PulseAudio server
          should use. By default, the "default.pa" configuration
          from the PulseAudio distribution is used.
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Literal string to append to <literal>configFile</literal>
          and the config file generated by the pulseaudio module.
        '';
      };

      extraClientConf = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Extra configuration appended to pulse/client.conf file.
        '';
      };

      package = mkOption {
        type = types.package;
        default = if config.services.jack.jackd.enable
                  then pkgs.pulseaudioFull
                  else pkgs.pulseaudio;
        defaultText = literalExpression "pkgs.pulseaudio";
        example = literalExpression "pkgs.pulseaudioFull";
        description = ''
          The PulseAudio derivation to use.  This can be used to enable
          features (such as JACK support, Bluetooth) via the
          <literal>pulseaudioFull</literal> package.
        '';
      };

      extraModules = mkOption {
        type = types.listOf types.package;
        default = [];
        example = literalExpression "[ pkgs.pulseaudio-modules-bt ]";
        description = ''
          Extra pulseaudio modules to use. This is intended for out-of-tree
          pulseaudio modules like extra bluetooth codecs.

          Extra modules take precedence over built-in pulseaudio modules.
        '';
      };

      daemon = {
        logLevel = mkOption {
          type = types.str;
          default = "notice";
          description = ''
            The log level that the system-wide pulseaudio daemon should use,
            if activated.
          '';
        };

        config = mkOption {
          type = types.attrsOf types.unspecified;
          default = {};
          description = "Config of the pulse daemon. See <literal>man pulse-daemon.conf</literal>.";
          example = literalExpression ''{ realtime-scheduling = "yes"; }'';
        };
      };

      zeroconf = {
        discovery.enable =
          mkEnableOption "discovery of pulseaudio sinks in the local network";
        publish.enable =
          mkEnableOption "publishing the pulseaudio sink in the local network";
      };

      # TODO: enable by default?
      tcp = {
        enable = mkEnableOption "tcp streaming support";

        port = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = ''
            The port number to listen on.
          '';
        };
        anonymousClients = {
          allowAll = mkEnableOption "all anonymous clients to stream to the server";
          allowedIpRanges = mkOption {
            type = types.listOf types.str;
            default = [];
            example = literalExpression ''[ "127.0.0.1" "192.168.1.0/24" ]'';
            description = ''
              A list of IP subnets that are allowed to stream to the server.
            '';
          };
        };
      };

    };

  };


  config = mkMerge [
    {
      environment.etc = {
        "pulse/client.conf".source = clientConf;
      };

      hardware.pulseaudio.configFile = mkDefault "${getBin overriddenPackage}/etc/pulse/default.pa";
    }

    (mkIf cfg.enable {
      environment.systemPackages = [ overriddenPackage ];

      sound.enable = true;

      environment.etc = {
        "asound.conf".source = alsaConf;

        "pulse/daemon.conf".source = writeText "daemon.conf"
          (lib.generators.toKeyValue {} cfg.daemon.config);

        "openal/alsoft.conf".source = writeText "alsoft.conf" "drivers=pulse";

        "libao.conf".source = writeText "libao.conf" "default_driver=pulse";
      };

      # Disable flat volumes to enable relative ones
      hardware.pulseaudio.daemon.config.flat-volumes = mkDefault "no";

      # Upstream defaults to speex-float-1 which results in audible artifacts
      hardware.pulseaudio.daemon.config.resample-method = mkDefault "speex-float-5";

      # Allow PulseAudio to get realtime priority using rtkit.
      security.rtkit.enable = true;

      systemd.packages = [ overriddenPackage ];

      # PulseAudio is packaged with udev rules to handle various audio device quirks
      services.udev.packages = [ overriddenPackage ];
    })

    (mkIf (cfg.extraModules != []) {
      hardware.pulseaudio.daemon.config.dl-search-path = let
        overriddenModules = builtins.map
          (drv: drv.override { pulseaudio = overriddenPackage; })
          cfg.extraModules;
        modulePaths = builtins.map
          (drv: "${drv}/${overriddenPackage.pulseDir}/modules")
          # User-provided extra modules take precedence
          (overriddenModules ++ [ overriddenPackage ]);
      in lib.concatStringsSep ":" modulePaths;
    })

    (mkIf hasZeroconf {
      services.avahi.enable = true;
    })
    (mkIf cfg.zeroconf.publish.enable {
      services.avahi.publish.enable = true;
      services.avahi.publish.userServices = true;
    })

    (mkIf nonSystemWide {
      environment.etc = {
        "pulse/default.pa".source = myConfigFile;
      };
      systemd.user = {
        services.pulseaudio = {
          restartIfChanged = true;
          serviceConfig = {
            RestartSec = "500ms";
            PassEnvironment = "DISPLAY";
          };
        } // optionalAttrs config.services.jack.jackd.enable {
          environment.JACK_PROMISCUOUS_SERVER = "jackaudio";
        };
        sockets.pulseaudio = {
          wantedBy = [ "sockets.target" ];
        };
      };
    })

    (mkIf systemWide {
      users.users.pulse = {
        # For some reason, PulseAudio wants UID == GID.
        uid = assert uid == gid; uid;
        group = "pulse";
        extraGroups = [ "audio" ];
        description = "PulseAudio system service user";
        home = stateDir;
        createHome = true;
        isSystemUser = true;
      };

      users.groups.pulse.gid = gid;

      systemd.services.pulseaudio = {
        description = "PulseAudio System-Wide Server";
        wantedBy = [ "sound.target" ];
        before = [ "sound.target" ];
        environment.PULSE_RUNTIME_PATH = stateDir;
        serviceConfig = {
          Type = "notify";
          ExecStart = "${binaryNoDaemon} --log-level=${cfg.daemon.logLevel} --system -n --file=${myConfigFile}";
          Restart = "on-failure";
          RestartSec = "500ms";
        };
      };

      environment.variables.PULSE_COOKIE = "${stateDir}/.config/pulse/cookie";
    })
  ];

}
