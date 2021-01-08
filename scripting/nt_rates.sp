#include <sourcemod>

#pragma semicolon 1

#define PLUGIN_VERSION "0.1.6"

#define MAX_RATE_LENGTH 9
#define MAX_MESSAGE_LENGTH 512

#define NEO_MAXPLAYERS 32

Handle hTimer_RateCheck = null;

ConVar hCvar_Interval, hCvar_DefaultRate, hCvar_DefaultCmdRate,
	hCvar_DefaultUpdateRate, hCvar_DefaultInterp, hCvar_MinInterp,
	hCvar_MaxInterp, hCvar_ForceInterp, hCvar_Verbosity;

new const String:g_tag[] = "[NT RATES]";

bool wasInterpFixedThisPass[NEO_MAXPLAYERS + 1];

enum {
	TYPE_RATE = 0,
	TYPE_CMDRATE,
	TYPE_UPDATERATE,
	TYPE_INTERP,
	TYPE_INTERP_ENABLED
};

enum {
	TYPE_MIN = 0,
	TYPE_MAX
};

enum {
	VERBOSITY_NONE = 0,
	VERBOSITY_PUBLIC,
	VERBOSITY_ADMIN_ONLY,

	VERBOSITY_MAX_VALUE = VERBOSITY_ADMIN_ONLY
};

public Plugin myinfo = {
	name			= "NT Rates",
	description	= "Improved interp and rate control.",
	author			= "Rain",
	version			= PLUGIN_VERSION,
	url				= "https://github.com/Rainyan/sourcemod-nt-rates"
};

public void OnPluginStart()
{
	hCvar_Interval				= CreateConVar("sm_rates_interval", "1.0", "Interval in seconds to check players' rate values.", _, true, 1.0);
	
	hCvar_DefaultRate			= CreateConVar("sm_rates_default_rate", "128000", "Default rate value.", _, true, 20000.0, true, 128000.0);
	hCvar_DefaultCmdRate		= CreateConVar("sm_rates_default_cmdrate", "66", "Default cl_cmdrate value.", _, true, 60.0, true, 66.0);
	hCvar_DefaultUpdateRate	= CreateConVar("sm_rates_default_updaterate", "66", "Default cl_updaterate value.", _, true, 60.0, true, 66.0);
	hCvar_DefaultInterp			= CreateConVar("sm_rates_default_interp", "0.02", "Default cl_interp value.", _, true, 0.0, true, 0.1);
	
	hCvar_MinInterp				= CreateConVar("sm_rates_min_interp", "0", "Minimum allowed cl_interp value.", _, true, 0.0, true, 0.02);
	hCvar_MaxInterp				= CreateConVar("sm_rates_max_interp", "0.1", "Maximum allowed cl_interp value.", _, true, 0.0, true, 0.1);
	hCvar_ForceInterp			= CreateConVar("sm_rates_force_interp", "1", "Whether or not to enforce clientside interp. This should be enabled.", _, true, 0.0, true, 1.0);
	
	hCvar_Verbosity				= CreateConVar("sm_rates_verbosity", "0", "0 - Don't publicly nag about bad values (pubs). \
1 - Nag about bad values (comp). 2 - Just notify admins about bad values (debug).",
		_, true, VERBOSITY_NONE * 1.0, true, VERBOSITY_MAX_VALUE * 1.0);
}

public void OnMapStart()
{
	hTimer_RateCheck = CreateTimer(hCvar_Interval.FloatValue , Timer_RateCheck, _, TIMER_REPEAT);

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
		if (!IsValidClient(client) || IsFakeClient(client))
		{
			continue;
		}
		
		wasInterpFixedThisPass[client] = false;
		
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
	
	decl String:rate			[MAX_RATE_LENGTH];
	decl String:cmdRate			[MAX_RATE_LENGTH];
	decl String:updateRate		[MAX_RATE_LENGTH];
	decl String:interp			[MAX_RATE_LENGTH];
	decl String:interpEnabled	[MAX_RATE_LENGTH];
	
	GetClientInfo(client, "rate", rate, MAX_RATE_LENGTH);
	GetClientInfo(client, "cl_cmdrate", cmdRate, MAX_RATE_LENGTH);
	GetClientInfo(client, "cl_updaterate", updateRate, MAX_RATE_LENGTH);
	GetClientInfo(client, "cl_interp", interp, MAX_RATE_LENGTH);
	GetClientInfo(client, "cl_interpolate", interpEnabled, MAX_RATE_LENGTH);
	
	int i;
	// Check rate
	for (i = 0; i < sizeof(rate); ++i) {
		if (strlen(rate[i]) < 1 && i > 0) // End of string
			break;
		
		if (!IsCharNumeric(rate[i])) {
			RestoreRate(client, TYPE_RATE);
			break;
		}
	}
	
	// Check cl_cmdrate validity
	for (i = 0; i < sizeof(cmdRate); ++i) {
		if (strlen(cmdRate[i]) < 1 && i > 0) // End of string
			break;
		
		if (!IsCharNumeric(cmdRate[i])) {
			RestoreRate(client, TYPE_CMDRATE);
			break;
		}
	}
	
	// Check cl_updaterate validity
	for (i = 0; i < sizeof(updateRate); ++i) {
		if (strlen(updateRate[i]) < 1) // End of string
			break;
		
		if ( !IsCharNumeric(updateRate[i]) ) {
			RestoreRate(client, TYPE_UPDATERATE);
			break;
		}
	}
	
	if (hCvar_ForceInterp.BoolValue) {
		// Make sure client has interp enabled
		float flInterpEnabled = StringToFloat(interpEnabled);
		if (flInterpEnabled != 1)
			RestoreRate(client, TYPE_INTERP_ENABLED);
	}
	
	// Check cl_interp validity
	int decimalPoints;
	bool wasDecimalLastChar;
	for (i = 0; i < sizeof(interp); ++i) {
		if (strlen(interp[i]) < 1 && i > 0) { // End of string
			// Interp ended in a decimal point instead of number (eg 0.)
			// This may be ok, but we're fixing it jic
			if (wasDecimalLastChar) {
				RestoreRate(client, TYPE_INTERP);
			}
			
			break;
		}
		
		// Decimal points are allowed in cl_interp
		if (StrContains(interp[i], ".") != -1) {
			if (decimalPoints > 0) { // There's more than 1 decimal point, something is wrong with interp
				// Hackhack: Dot indexing has something funky going on, just ignoring the dot from last array index here
				if (wasDecimalLastChar) {
					wasDecimalLastChar = false;
					continue;
				}
				
				RestoreRate(client, TYPE_INTERP);
				break;
			}
			wasDecimalLastChar = true;
			++decimalPoints;
			
			continue;
		}
		
		else if (!IsCharNumeric(interp[i])) {
			RestoreRate(client, TYPE_INTERP);
			break;
		}
		
		wasDecimalLastChar = false;
	}
	
	// This player's cl_interp was just reset to defaults this pass.
	// Stop here, so we don't nag about incorrect values again needlessly.
	if (wasInterpFixedThisPass[client])
		return;
	
	float flInterp = StringToFloat(interp);
	
	if (flInterp < hCvar_MinInterp.FloatValue)
		CapInterp(client, TYPE_MIN);
	
	else if (flInterp > hCvar_MaxInterp.FloatValue)
		CapInterp(client, TYPE_MAX);
}

void RestoreRate(const int client, const int rateType)
{
	if (!IsValidClient(client)) {
		return;
	}

	int verbosity = hCvar_Verbosity.IntValue;

	decl String:msg[MAX_MESSAGE_LENGTH];
	decl String:clientName[MAX_NAME_LENGTH];

	if (verbosity > VERBOSITY_NONE) {
		GetClientName(client, clientName, sizeof(clientName));
	}

	switch (rateType)
	{
		case TYPE_RATE:
		{
			decl String:defaultRate[MAX_RATE_LENGTH];
			GetConVarString(hCvar_DefaultRate, defaultRate, sizeof(defaultRate));
			
			ClientCommand(client, "rate %s", defaultRate);
			
			if (verbosity > VERBOSITY_NONE)
			{
				Format(msg, sizeof(msg), "%s Player \"%s\" had an invalid rate. Value has been reset to \"%s\"",
					g_tag, clientName, defaultRate);
			}
		}
		
		case TYPE_CMDRATE:
		{
			decl String:defaultCmdRate[MAX_RATE_LENGTH];
			GetConVarString(hCvar_DefaultCmdRate, defaultCmdRate, sizeof(defaultCmdRate));
			
			ClientCommand(client, "cl_cmdrate %s", defaultCmdRate);
			
			if (verbosity > VERBOSITY_NONE)
			{
				Format(msg, sizeof(msg), "%s Player \"%s\" had an invalid cl_cmdrate. Value has been reset to \"%s\"",
					g_tag, clientName, defaultCmdRate);
			}
		}
		
		case TYPE_UPDATERATE:
		{
			decl String:defaultUpdateRate[MAX_RATE_LENGTH];
			GetConVarString(hCvar_DefaultUpdateRate, defaultUpdateRate, sizeof(defaultUpdateRate));
			
			ClientCommand(client, "cl_updaterate %s", defaultUpdateRate);
			
			if (verbosity > VERBOSITY_NONE)
			{
				Format(msg, sizeof(msg), "%s Player \"%s\" had an invalid cl_updaterate. Value has been reset to \"%s\"",
					g_tag, clientName, defaultUpdateRate);
			}
		}
		
		case TYPE_INTERP:
		{
			wasInterpFixedThisPass[client] = true;
			
			decl String:defaultInterp[MAX_RATE_LENGTH];
			GetConVarString(hCvar_DefaultInterp, defaultInterp, sizeof(defaultInterp));
			
			ClientCommand(client, "cl_interp %s", defaultInterp);
			
			if (verbosity > 0)
			{
				Format(msg, sizeof(msg), "%s Player \"%s\" had an invalid cl_interp. Value has been reset to \"%s\"",
					g_tag, clientName, defaultInterp);
			}
		}
		
		case TYPE_INTERP_ENABLED:
		{
			ClientCommand(client, "cl_interpolate 1");
			
			if (verbosity > 0)
			{
				Format(msg, sizeof(msg), "%s Player \"%s\" had interpolation disabled. This has been reverted.",
					g_tag, clientName);
			}
		}
	}
	
	if (verbosity == VERBOSITY_PUBLIC)
	{
		PrintToChatAll(msg);
	}
	else if (verbosity == VERBOSITY_ADMIN_ONLY)
	{
		PrintToAdminsChat(msg);
	}
}

void CapInterp(const int client, const int capType)
{
	if (!IsValidClient(client))
		return;
	
	int verbosity = hCvar_Verbosity.IntValue;
	
	decl String:msg[MAX_MESSAGE_LENGTH];
	decl String:clientName[MAX_NAME_LENGTH];
	
	if (verbosity > VERBOSITY_NONE) {
		GetClientName(client, clientName, sizeof(clientName));
	}
	
	switch (capType)
	{
		case TYPE_MIN:
		{
			decl String:minInterp[MAX_RATE_LENGTH];
			GetConVarString(hCvar_MinInterp, minInterp, sizeof(minInterp));
			
			ClientCommand(client, "cl_interp %s", minInterp);
			
			if (verbosity > VERBOSITY_NONE)
			{
				Format(msg, sizeof(msg), "%s Player \"%s\" had smaller cl_interp than allowed. Value has been capped to the minimum \"%s\"",
					g_tag, clientName, minInterp);
			}
		}
		
		case TYPE_MAX:
		{
			decl String:maxInterp[MAX_RATE_LENGTH];
			GetConVarString(hCvar_MaxInterp, maxInterp, sizeof(maxInterp));
			
			ClientCommand(client, "cl_interp %s", maxInterp);
			
			if (verbosity > VERBOSITY_NONE)
			{
				Format(msg, sizeof(msg), "%s Player \"%s\" had bigger cl_interp than allowed. Value has been capped to the maximum \"%s\"",
					g_tag, clientName, maxInterp);
			}
		}
	}
	
	if (verbosity == VERBOSITY_PUBLIC)
	{
		PrintToChatAll(msg);
	}
	else if (verbosity == VERBOSITY_ADMIN_ONLY)
	{
		PrintToAdminsChat(msg);
	}
}

bool IsValidClient(const int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

void PrintToAdminsChat(const char[] message)
{
	for (int client = 1; client <= MaxClients; ++client) {
		if (!IsValidClient(client) || !GetAdminFlag(GetUserAdmin(client), Admin_Generic))
		{
			continue;
		}
		
		PrintToChat(client, message);
	}
}

float Clamp(const float value, const float min, const float max)
{
	return value < min ? min : value > max ? max : value;
}
