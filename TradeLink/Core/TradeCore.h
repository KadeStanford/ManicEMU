// SPDX-License-Identifier: AGPL-3.0-or-later
#ifndef MANIC_TRADE_CORE_H
#define MANIC_TRADE_CORE_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#define MT_SAVE_SIZE 131072
#define MT_DATA_SIZE 24
#define MT_PACKET_SIZE 56
#define MT_QUEUE_SIZE 512
enum MTPhase { MT_OFF, MT_IDLE, MT_WAITING, MT_LINKED, MT_SUSPENDED, MT_RESTORE, MT_CANCELLED, MT_BROKEN, MT_CLOSING };
enum MTMode { MT_MODE_UNKNOWN, MT_MODE_TRADE, MT_MODE_SINGLE_BATTLE, MT_MODE_DOUBLE_BATTLE };
typedef struct {
    void (*start)(unsigned role);
    void (*receive)(const void *, size_t, unsigned peer);
    void (*stop)(void);
    size_t (*state_size)(void);
    bool (*save_state)(void *, size_t);
    bool (*load_state)(const void *, size_t);
    uint8_t *battery;
} MTGBA;
typedef void (*MTSnapshot)(const uint8_t *battery, const uint8_t *state, size_t state_size);
typedef void (*MTNotice)(const char *message);
typedef int (*MTPersist)(const uint8_t *battery, const uint8_t *state, size_t state_size);
void MT_install(MTSnapshot snapshot, MTNotice stopped, MTNotice error);
void MT_set_persist(MTPersist persist); // Core thread: current SRAM + post-link backup, never the old checkpoint.
void MT_enable(int enabled);
int MT_game_code(const uint8_t code[4]);
int MT_compatible(const uint8_t a[4], const uint8_t b[4]);
void MT_loaded(const char *path, const uint8_t code[4]);
void MT_unloaded(void);
const char *MT_path(void);
const uint8_t *MT_code(void);
int MT_active(void);
enum MTPhase MT_phase(void);
void MT_request(void); // Called at the first Gen3 cable handshake, on core thread.
void MT_leave(void);
int MT_complete(void); // Read-only. Completion is applied and announced by MT_frame.
int MT_finishing(void);
int MT_local_closed(void);
int MT_peer_disconnected(void); // Expected only after ordered close fences, never commits an interrupted link.
uint64_t MT_epoch(void); // Guards queued frontend callbacks across games/sessions.
enum MTMode MT_mode(void); // In-game LINKCMD_SEND_LINK_TYPE; no user mode switch.
size_t MT_pending(void);
int MT_frame(const MTGBA *gba); // Core thread only. No UI/network code executes here.
void MT_connect(unsigned role, const uint8_t session[16]);
void MT_suspend(void);
void MT_resume(void);
void MT_cancel(void);
void MT_restore(void);
void MT_send(uint16_t recipient, const void *data, size_t size);
void MT_failure(const char *message); // A lost/invalid core packet requires rollback.
void MT_poll_receive(void);
int MT_next_packet(uint64_t after, uint8_t packet[MT_PACKET_SIZE]);
// DATA is acknowledged once retained for delivery on the core thread. Duplicate
// retransmissions receive ACKs but never execute again. Session ID survives resume.
int MT_receive_packet(const uint8_t *packet, size_t size, uint8_t ack[MT_PACKET_SIZE]);
void MT_ack_packet(uint8_t packet[MT_PACKET_SIZE]);
uint64_t MT_received(void);
uint64_t MT_sent(void);
#endif
