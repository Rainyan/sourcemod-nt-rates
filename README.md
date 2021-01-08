# sourcemod-nt-rates

Neotokyo SM plugin for improved interp and rate control.

## Compile requirements

- SourceMod 1.7 or newer

## Usage

This plugin is completely automatic. You can change the cvars below to modify the behaviour, but the defaults should be good as they are for a 66 tick server.

Note: If you're using this plugin for a competitive server, it's recommended you set the *sm_rates_verbosity* to a value of 1 (publicly announce offending rate values).

## Cvars

These cvars can be set in the file cfg/sourcemod/plugin.nt_rates.cfg. If the file doesn't exist, it is automatically generated on first run of this plugin.

* *sm_rates_version* — Plugin version.
* *sm_rates_interval* — Interval (in seconds) to check players' rate values. Default: 1. Range: (1 - 60).
* *sm_rates_default_rate* — Default rate value when restoring invalid value. Default: 128000. Range: (5000 - 786432).
* *sm_rates_default_cmdrate* — Default cl_cmdrate value when restoring invalid value. Default: 66. Range: (20 - 128).
* *sm_rates_default_updaterate* — Default cl_updaterate value when restoring invalid value. Default: 66. Range: (20 - 128).
* *sm_rates_default_interp* — Default cl_interp value when restoring invalid value. Default: 0.030303. Range: (0 - 0.1).
* *sm_rates_min_interp* — Minimum allowed cl_interp value. Default: 0. Range: (0 - 0.0303030).
* *sm_rates_max_interp* — Maximum allowed cl_interp value. Default: 0.1. Range: (0.0151515 - 0.1).
* *sm_rates_force_interp* — Whether or not to enforce clientside cl_interpolate. Default: 1. Range: (0 - 1).
* *sm_rates_verbosity* — 0: Don't publicly announce bad values, just silently fix them. 1: Publicly announce bad values (recommended for competitive). 2: Only notify admins about bad values. Default: 2. Range: (0 - 2).
* *sm_rates_log* — Whether to write rate violations to log file. Default: 1. Range: (0 - 1).
