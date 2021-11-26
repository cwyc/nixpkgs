{config, lib, pkgs, ... }:
with lib;
let
  customSystemd = pkgs.systemd.override {
    withCryptsetup = true;
    tpm2-tss = pkgs.tpm2-tss.override { loader-path-patch = false; };
  };
  openCommand = config: ''
    systemd-cryptsetup ${config.volumeName} ${config.encryptedDevice} ${config.keyFile} ${config.options}
  '';
in {
  options.boot.systemd-cryptsetup = with types; {
    devices = mkOption {
      description = ''
        The devices that should be unlocked using systemd-cryptsetup during the boot process. </para><para>
        The attribute name corresponds to the name of the resulting encrypted volume; its block device is set up below
       /dev/mapper/. </para><para>
        Corresponds to the fields in crypttab. See the <literal>crypttab(5)</literal> manpage.
        
      '';
      default = {};
      type = attrsOf ( submodule {
        # Descriptions are taken from the manpage.
        encryptedDevice = mkOption {
          description = ''
            A path to the underlying block device or file, or a specification of a block device via "UUID=" followed by the UUID
          '';
          type = str;
        };
        keyFile = mkOption {
          description = ''
            An absolute path to a file with the encryption key. </para><para>
            Optionally, the path may be followed by ":" and an fstab device specification (e.g. starting with "LABEL=" or similar); 
            in which case the path is taken relative to the device file system root. </para><para>
            If the field is not present or is "none" or "-", a key file named after the volume to unlock (i.e. the first column of the line), 
            suffixed with .key is automatically loaded from the /etc/cryptsetup-keys.d/ and /run/cryptsetup-keys.d/ directories, if present. </para><para>
            Otherwise, the password has to be manually entered during system boot.</para><para>
            
            For swap encryption, /dev/urandom may be used as key file.
          '';
          type = str;
          default = "-";
        };
        options = mkOption {
          description = ''
            A comma-delimited list of options. See the <literal>crypttab(5)</literal> manpage for a full list of options.
          '';
          type = str;
          default = "";
          example = "tpm2-device=auto,readonly";
        };
        preLVM = mkOption {
          description = ''
            Whether the device mount will be attempted before LVM scan or after it.
          '';
          default = true;
          type = types.bool;
        };
      });
    };
  };
  config = optionalAttrs /*(options.boot.systemd-cryptsetup.devices != {})*/ true {
    boot.initrd.extraUtilsCommands = ''
      copy_bin_and_libs ${customSystemd}/lib/systemd/system-generators/systemd-cryptsetup-generator
    '';
    boot.initrd.extraUtilsCommandsTest = ''
    '';

    boot.initrd.postDeviceCommands =  concatStrings (map openCommand (filter (config: !config.preLVM) config.boot.systemd-cryptsetup.devices));
    boot.initrd.preLVMCommands =      concatStrings (map openCommand (filter (config: config.preLVM ) config.boot.systemd-cryptsetup.devices));
  };

}