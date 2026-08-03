#ifndef ARTI_H
#define ARTI_H

#include <stdint.h>
#include <stdbool.h>

/**
 * Start Arti with a SOCKS5 proxy.
 *
 * # Arguments
 * * `data_dir` - Path to data directory for Tor state (C string)
 * * `socks_port` - Port for SOCKS5 proxy (e.g., 39050)
 *
 * # Returns
 * * 0 on success
 * * -1 if already running
 * * -2 if data_dir is invalid
 * * -3 if runtime initialization failed
 * * -4 if bootstrap failed
 */
int arti_start(const char *data_dir, uint16_t socks_port);

/**
 * Start Arti and route all of its outbound TCP connections through an outer proxy.
 *
 * `proxy_kind` is 1 for SOCKS5 and 2 for HTTP CONNECT. Credentials must either both
 * be null or both contain valid UTF-8 strings.
 */
int arti_start_with_proxy(const char *data_dir,
                          uint16_t socks_port,
                          uint8_t proxy_kind,
                          const char *proxy_host,
                          uint16_t proxy_port,
                          const char *username,
                          const char *password);

/**
 * Stop Arti gracefully.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 */
int arti_stop(void);

/**
 * Check if Arti is currently running.
 *
 * # Returns
 * * 1 if running
 * * 0 if not running
 */
int arti_is_running(void);

/**
 * Get the current bootstrap progress (0-100).
 */
int arti_bootstrap_progress(void);

/**
 * Get the current bootstrap summary string.
 *
 * # Arguments
 * * `buf` - Buffer to write the summary into
 * * `len` - Length of the buffer
 *
 * # Returns
 * * Number of bytes written (not including null terminator)
 * * -1 if buffer is null or too small
 */
int arti_bootstrap_summary(char *buf, int len);

/**
 * Signal Arti to go dormant (reduce resource usage).
 * This is a hint; Arti may not fully support dormant mode yet.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 */
int arti_go_dormant(void);

/**
 * Signal Arti to wake from dormant mode.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 */
int arti_wake(void);

#endif  /* ARTI_H */
