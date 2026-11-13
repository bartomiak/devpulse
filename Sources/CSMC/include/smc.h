#ifndef CSMC_SMC_H
#define CSMC_SMC_H

/// Opens a connection to AppleSMC. Returns 0 on success.
int smc_open(void);

/// Closes the AppleSMC connection.
void smc_close(void);

/// Reads a temperature (°C) for a 4-character SMC key, e.g. "TC0P".
/// Returns a value < 0 if the key doesn't exist or has an unsupported type.
double smc_read_temperature(const char *key);

/// Reads any numeric value (sp78, fpe2, flt, ui8/16/32), e.g. "F0Ac" – fan speed.
/// Returns NAN if the key doesn't exist or has an unsupported type.
double smc_read_value(const char *key);

#endif
