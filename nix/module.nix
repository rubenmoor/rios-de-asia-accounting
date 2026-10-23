# Daily backup of the airbnb-books database: a systemd user service plus timer.
# One file for both module systems; `flavor` is "nixos" or "home-manager".
{ self, flavor }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.airbnb-books-backup;
  # `--db` is a global option: it goes before the subcommand
  command = lib.escapeShellArgs (
    [ "${cfg.package}/bin/airbnb-books" ]
    ++ lib.optionals (cfg.dbPath != null) [ "--db" cfg.dbPath ]
    ++ [ "backup" "--backup-dir" cfg.backupDir "--keep" (toString cfg.keep) ]
  );
  description = "Back up the airbnb-books database";
  units =
    if flavor == "nixos" then {
      systemd.user.services.airbnb-books-backup = {
        inherit description;
        serviceConfig = { Type = "oneshot"; ExecStart = command; };
      };
      systemd.user.timers.airbnb-books-backup = {
        inherit description;
        wantedBy = [ "timers.target" ];
        timerConfig = { OnCalendar = cfg.onCalendar; Persistent = true; };
      };
    } else {
      systemd.user.services.airbnb-books-backup = {
        Unit.Description = description;
        Service = { Type = "oneshot"; ExecStart = command; };
      };
      systemd.user.timers.airbnb-books-backup = {
        Unit.Description = description;
        Timer = { OnCalendar = cfg.onCalendar; Persistent = true; };
        Install.WantedBy = [ "timers.target" ];
      };
    };
in
{
  options.services.airbnb-books-backup = {
    enable = lib.mkEnableOption "the daily airbnb-books database backup";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "airbnb-books flake package";
      description = "The airbnb-books package providing the `airbnb-books` command.";
    };
    backupDir = lib.mkOption {
      type = lib.types.str;
      example = "/home/me/Dropbox/airbnb-books";
      description = "Folder that receives books-YYYY-MM-DD.db.";
    };
    keep = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "How many daily backups to keep.";
    };
    dbPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Live database file; null uses the app's default location.";
    };
    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd OnCalendar expression for the backup.";
    };
  };

  config = lib.mkIf cfg.enable units;
}
