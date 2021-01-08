#include <sourcemod>
#include <sdktools>

#pragma semicolon 1

#define PLUGIN_VERSION "0.2"

#define MAX_RATE_LENGTH 9
#define MAX_MESSAGE_LENGTH 512

#define NEO_MAX_PLAYERS 32

#define MAX_RATE_CVAR_NAME_LENGTH (14 + 1) // "cl_interpolate" + 0

Handle hTimer_RateCheck = null;

ConVar hCvar_Interval, hCvar_DefaultRate, hCvar_DefaultCmdRate,
    hCvar_DefaultUpdateRate, hCvar_DefaultInterp, hCvar_MinInterp,
    hCvar_MaxInterp, hCvar_ForceInterp, hCvar_Verbosity,
    hCvar_LogToFile,
    // native cvars
    hCvar_Rate, hCvar_CmdRate, hCvar_UpdateRate,
    hCvar_Interp, hCvar_Interpolate;

static const String:g_sTag[] = "[NT RATES]";

bool g_bWasInterpFixedThisPass[NEO_MAX_PLAYERS + 1];

enum RATE_TYPE {
    RATE_TYPE_RATE = 0,
    RATE_TYPE_CMDRATE,
    RATE_TYPE_UPDATERATE,
    RATE_TYPE_INTERP,
    RATE_TYPE_INTERP_ENABLED,
    NUM_RATE_TYPES
};

enum RATE_LIMIT_TYPE {
    RATE_LIMIT_TYPE_MIN = 0,
    RATE_LIMIT_TYPE_MAX
};

enum {
    VERBOSITY_NONE = 0,
    VERBOSITY_PUBLIC,
    VERBOSITY_ADMIN_ONLY,

    NUM_VERBOSITY_TYPES,
    VERBOSITY_MAX_VALUE = NUM_VERBOSITY_TYPES - 1
};

public Plugin myinfo = {
    name               = "NT Rates",
    description        = "Improved interp and rate control.",
    author             = "Rain",
    version            = PLUGIN_VERSION,
    url                = "https://github.com/Rainyan/sourcemod-nt-rates"
};

public void OnPluginStart()
{
    hCvar_Interval                = CreateConVar("sm_rates_interval", "1.0", "Interval (in seconds) to check players' rate values.", _, true, 1.0, true, 60.0);
    hCvar_DefaultRate             = CreateConVar("sm_rates_default_rate", "128000", "Default rate value.", _, true, 5000.0, true, 786432.0);
    hCvar_DefaultCmdRate          = CreateConVar("sm_rates_default_cmdrate", "66", "Default cl_cmdrate value.", _, true, 20.0, true, 128.0);
    hCvar_DefaultUpdateRate       = CreateConVar("sm_rates_default_updaterate", "66", "Default cl_updaterate value.", _, true, 20.0, true, 128.0);
    hCvar_DefaultInterp           = CreateConVar("sm_rates_default_interp", "0.030303", "Default cl_interp value.", _, true, 0.0, true, 0.1);
    hCvar_MinInterp               = CreateConVar("sm_rates_min_interp", "0", "Minimum allowed cl_interp value.", _, true, 0.0, true, 0.0303030);
    hCvar_MaxInterp               = CreateConVar("sm_rates_max_interp", "0.1", "Maximum allowed cl_interp value.", _, true, 0.0151515, true, 0.1);
    hCvar_ForceInterp             = CreateConVar("sm_rates_force_interp", "1", "Whether or not to enforce clientside interp.", _, true, 0.0, true, 1.0);
    hCvar_Verbosity               = CreateConVar("sm_rates_verbosity", "0", "0 - Don't publicly nag about bad values (pubs). \
1 - Nag about bad values (comp). 2 - Just notify admins about bad values (debug).", _, true, VERBOSITY_NONE * 1.0, true, VERBOSITY_MAX_VALUE * 1.0);
    hCvar_LogToFile               = CreateConVar("sm_rates_log", "1", "Whether to log rate violations to file.", _, true, 0.0, true, 1.0);

    hCvar_Rate        = FindConVar("rate");
    hCvar_CmdRate     = FindConVar("cl_cmdrate");
    hCvar_UpdateRate  = FindConVar("cl_updaterate");
    hCvar_Interp      = FindConVar("cl_interp");
    hCvar_Interpolate = FindConVar("cl_interpolate");
    if (hCvar_Rate == null) {
        SetFailState("Failed to find native cvar \"rate\"");
    }
    else if (hCvar_CmdRate == null) {
        SetFailState("Failed to find native cvar \"cl_cmdrate\"");
    }
    else if (hCvar_UpdateRate == null) {
        SetFailState("Failed to find native cvar \"cl_updaterate\"");
    }
    else if (hCvar_Interp == null) {
        SetFailState("Failed to find native cvar \"cl_interp\"");
    }
    else if (hCvar_Interpolate == null) {
        SetFailState("Failed to find native cvar \"cl_interpolate\"");
    }

    hTimer_RateCheck = CreateTimer(hCvar_Interval.FloatValue , Timer_RateCheck, _, TIMER_REPEAT);

    AutoExecConfig();
}

public void OnMapStart()
{
    HookConVarChange(hCvar_Interval, CvarChanged_Interval);
}

void CvarChanged_Interval(ConVar convar, const char[] oldValue, const char[] newValue)
{
    float min, max;
    convar.GetBounds(ConVarBound_Lower, min);
    convar.GetBounds(ConVarBound_Upper, max);

    delete hTimer_RateCheck;
    hTimer_RateCheck = CreateTimer(Clamp(StringToFloat(newValue), min, max), Timer_RateCheck, _, TIMER_REPEAT);
}

public Action Timer_RateCheck(Handle timer)
{
    for (int client = 1; client <= MaxClients; ++client) {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }
        g_bWasInterpFixedThisPass[client] = false;
        ValidateRates(client);
    }
    return Plugin_Continue;
}

// Make sure rates are properly formatted
void ValidateRates(const int client)
{
    if (!IsValidClient(client)) {
        return;
    }

    decl String:rate                [MAX_RATE_LENGTH];
    decl String:cmdRate             [MAX_RATE_LENGTH];
    decl String:updateRate          [MAX_RATE_LENGTH];
    decl String:interp              [MAX_RATE_LENGTH];
    decl String:interpEnabled       [MAX_RATE_LENGTH];
    GetClientInfo(client, "rate",              rate,             MAX_RATE_LENGTH);
    GetClientInfo(client, "cl_cmdrate",        cmdRate,          MAX_RATE_LENGTH);
    GetClientInfo(client, "cl_updaterate",     updateRate,       MAX_RATE_LENGTH);
    GetClientInfo(client, "cl_interp",         interp,           MAX_RATE_LENGTH);
    GetClientInfo(client, "cl_interpolate",    interpEnabled,    MAX_RATE_LENGTH);
    int rate_len       = strlen(rate);
    int cmdRate_len    = strlen(cmdRate);
    int updateRate_len = strlen(updateRate);
    int interp_len     = strlen(interp);
    int i = 0;

    // Check rate
    for (; i < MAX_RATE_LENGTH && i < rate_len; ++i) {
        if (!IsCharNumeric(rate[i])) {
            RestoreRate(client, RATE_TYPE_RATE);
            break;
        }
    }

    // Check cl_cmdrate validity
    for (i = 0; i < MAX_RATE_LENGTH && i < cmdRate_len; ++i) {
        if (!IsCharNumeric(cmdRate[i])) {
            RestoreRate(client, RATE_TYPE_CMDRATE);
            break;
        }
    }

    // Check cl_updaterate validity
    for (i = 0; i < MAX_RATE_LENGTH && i < updateRate_len; ++i) {
        if (!IsCharNumeric(updateRate[i])) {
            RestoreRate(client, RATE_TYPE_UPDATERATE);
            break;
        }
    }

    if (hCvar_ForceInterp.BoolValue) {
        // Make sure client has cl_interpolate enabled
        float flInterpEnabled = StringToFloat(interpEnabled);
        if (flInterpEnabled != 1) {
            RestoreRate(client, RATE_TYPE_INTERP_ENABLED);
        }
    }

    // Check cl_interp validity
    int decimalPoints;
    for (i = 0; i < MAX_RATE_LENGTH && i < interp_len; ++i) {
        // Decimal points are allowed in cl_interp
        if (interp[i] == '.') {
            // Interp ended in a decimal point instead of number (eg 0.)
            // This may be ok, but we're fixing it jic
            if (i + 1 == interp_len ||
                // There's more than 1 decimal point, something is wrong with interp
                ++decimalPoints > 1)
            {
                RestoreRate(client, RATE_TYPE_INTERP);
                break;
            }
        }
        else if (!IsCharNumeric(interp[i])) {
            RestoreRate(client, RATE_TYPE_INTERP);
            break;
        }
    }

    // Only do this if the player's cl_interp was not just reset to defaults on this pass.
    // This way we won't needlessly nag about incorrect values multiple times in a row.
    if (!g_bWasInterpFixedThisPass[client]) {
        float flInterp = StringToFloat(interp);
        if (flInterp < hCvar_MinInterp.FloatValue) {
            CapInterp(client, RATE_LIMIT_TYPE_MIN);
        }
        else if (flInterp > hCvar_MaxInterp.FloatValue) {
            CapInterp(client, RATE_LIMIT_TYPE_MAX);
        }
    }
}

void RestoreRate(const int client, const RATE_TYPE rateType)
{
    if (!IsValidClient(client)) {
        return;
    }

    decl String:defaultValue[MAX_RATE_LENGTH];
    decl String:cvarName[MAX_RATE_CVAR_NAME_LENGTH];

    switch (rateType)
    {
        case RATE_TYPE_RATE:
        {
            hCvar_DefaultRate.GetString(defaultValue, sizeof(defaultValue));
            hCvar_Rate.GetName(cvarName, sizeof(cvarName));
        }
        case RATE_TYPE_CMDRATE:
        {
            hCvar_DefaultCmdRate.GetString(defaultValue, sizeof(defaultValue));
            hCvar_CmdRate.GetName(cvarName, sizeof(cvarName));
        }
        case RATE_TYPE_UPDATERATE:
        {
            hCvar_DefaultUpdateRate.GetString(defaultValue, sizeof(defaultValue));
            hCvar_UpdateRate.GetName(cvarName, sizeof(cvarName));
        }
        case RATE_TYPE_INTERP:
        {
            hCvar_DefaultInterp.GetString(defaultValue, sizeof(defaultValue));
            hCvar_Interp.GetName(cvarName, sizeof(cvarName));
        }
        case RATE_TYPE_INTERP_ENABLED:
        {
            strcopy(defaultValue, sizeof(defaultValue), "1");
            hCvar_Interpolate.GetName(cvarName, sizeof(cvarName));
        }
        default:
        {
            SetFailState("Unexpected rate type: %d", rateType);
        }
    }
    ClientCommand(client, "%s %s", cvarName, defaultValue);
    NotifyRestore(client, rateType, cvarName);
}

void CapInterp(const int client, const RATE_LIMIT_TYPE capType)
{
    if (!IsValidClient(client)) {
        return;
    }
    decl String:restoredInterp[MAX_RATE_LENGTH];
    GetConVarString((capType == RATE_LIMIT_TYPE_MIN) ? hCvar_MinInterp : hCvar_MaxInterp, restoredInterp, sizeof(restoredInterp));
    ClientCommand(client, "cl_interp %s", restoredInterp);
    NotifyRestore(client, RATE_TYPE_INTERP, "cl_interp", true, capType);
}

bool IsValidClient(const int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

void NotifyRestore(const int client, const RATE_TYPE rate_type, const char[] rate_type_name, const bool is_limit_type = false, const RATE_LIMIT_TYPE limit_type = RATE_LIMIT_TYPE_MIN)
{
    if (hCvar_Verbosity.IntValue == VERBOSITY_NONE || !IsValidClient(client)) {
        return;
    }
    float restored_value;
    if (!is_limit_type) {
        switch (rate_type)
        {
            case RATE_TYPE_RATE:
            {
                restored_value = hCvar_DefaultRate.FloatValue;
            }
            case RATE_TYPE_CMDRATE:
            {
                restored_value = hCvar_DefaultCmdRate.FloatValue;
            }
            case RATE_TYPE_UPDATERATE:
            {
                restored_value = hCvar_DefaultUpdateRate.FloatValue;
            }
            case RATE_TYPE_INTERP:
            {
                restored_value = hCvar_DefaultInterp.FloatValue;
            }
            case RATE_TYPE_INTERP_ENABLED:
            {
                restored_value = hCvar_ForceInterp.FloatValue;
            }
            default:
            {
                SetFailState("Unsupported rate type: %d (is_limit_type: %d)", rate_type, is_limit_type);
            }
        }
    }
    else {
        switch (rate_type)
        {
            case RATE_TYPE_RATE:
            {
                hCvar_Rate.GetBounds((limit_type == RATE_LIMIT_TYPE_MIN) ? ConVarBound_Lower : ConVarBound_Upper, restored_value);
            }
            case RATE_TYPE_CMDRATE:
            {
                hCvar_CmdRate.GetBounds((limit_type == RATE_LIMIT_TYPE_MIN) ? ConVarBound_Lower : ConVarBound_Upper, restored_value);
            }
            case RATE_TYPE_UPDATERATE:
            {
                hCvar_UpdateRate.GetBounds((limit_type == RATE_LIMIT_TYPE_MIN) ? ConVarBound_Lower : ConVarBound_Upper, restored_value);
            }
            default:
            {
                SetFailState("Unsupported rate type: %d (is_limit_type: %d)", rate_type, is_limit_type);
            }
        }
    }
    decl String:clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));
    switch (hCvar_Verbosity.IntValue) {
        case VERBOSITY_PUBLIC:
        {
            PrintToChatAll("%s Player \"%s\" had %s value of \"%s\" than allowed. The value has been %s to the %s of \"%f\".",
                g_sTag,
                clientName,
                is_limit_type ? ((limit_type == RATE_LIMIT_TYPE_MIN) ? "smaller" : "larger") : "invalid",
                rate_type_name,
                is_limit_type ? "capped" : "restored",
                is_limit_type ? ((limit_type == RATE_LIMIT_TYPE_MIN) ? "minimum" : "maximum") : "default",
                restored_value);
        }
        case VERBOSITY_ADMIN_ONLY:
        {
            PrintToAdmins(true, true, "%s Player \"%s\" had %s value of \"%s\" than allowed. The value has been %s to the %s of \"%f\".",
                g_sTag,
                clientName,
                is_limit_type ? ((limit_type == RATE_LIMIT_TYPE_MIN) ? "smaller" : "larger") : "invalid",
                rate_type_name,
                is_limit_type ? "capped" : "restored",
                is_limit_type ? ((limit_type == RATE_LIMIT_TYPE_MIN) ? "minimum" : "maximum") : "default",
                restored_value);
        }
    }

    if (hCvar_LogToFile.BoolValue) {
        char clientAuthId[32];
        GetClientAuthId(client, AuthId_Steam2, clientAuthId, sizeof(clientAuthId));

        char teamName[11]; // strlen of "Unassigned" + \0
        GetTeamName(GetClientTeam(client), teamName, sizeof(teamName));

        LogToGame("%s: \"%s<%d><%s><%s>\" had invalid client side cvar value of \"%s\". It has been restored within acceptable bounds.",
            g_sTag, clientName, GetClientUserId(client), clientAuthId, teamName, rate_type_name);
    }
}

stock void PrintToAdmins(const bool toChat = true, const bool toConsole = false, const char[] message, any ...)
{
    decl String:formatMsg[MAX_MESSAGE_LENGTH];
    VFormat(formatMsg, sizeof(formatMsg), message, 4);

    for (int client = 1; client <= MaxClients; ++client) {
        if (!IsValidClient(client) || !IsAdmin(client)) {
            continue;
        }

        if (toChat) {
            PrintToChat(client, formatMsg);
        }
        if (toConsole) {
            PrintToConsole(client, formatMsg);
        }
    }
}

stock float Clamp(const float value, const float min, const float max)
{
    return value < min ? min : value > max ? max : value;
}

stock bool IsAdmin(const int client)
{
    if (!IsValidClient(client) || !IsClientAuthorized(client)) {
        return false;
    }
    AdminId adminId = GetUserAdmin(client);
    if (adminId == INVALID_ADMIN_ID) {
        return false;
    }
    return GetAdminFlag(adminId, Admin_Generic);
}
