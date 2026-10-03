"""Exercise real Gen3 gpSP serial words across fragmented loopback TCP.

The legal fixture does not implement Pokemon game logic. This validates the
engine/transport boundary, not completion of an actual in-game trade.
"""
import socket
import subprocess
import sys
import time


class Peer:
    def __init__(self, role):
        self.proc = subprocess.Popen([sys.argv[1], str(role)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, bufsize=1)
        self.pending = []
        self.acks = []
        self.reg = []
        self.read()

    def read(self):
        while True:
            line = self.proc.stdout.readline().strip()
            if not line:
                assert self.proc.poll() is None, 'core process failed'
                continue
            if line == 'END':
                return
            if line.startswith('PACKET '):
                self.pending.append(bytes.fromhex(line[7:]))
            elif line.startswith('ACK '):
                self.acks.append(bytes.fromhex(line[4:]))
            elif line.startswith('REG '):
                words = line.split()
                self.reg = [int(v, 16) for v in words[1:5]]
                self.phase = int(words[6])
                self.rx = int(words[10])

    def command(self, text):
        self.proc.stdin.write(text + '\n')
        self.proc.stdin.flush()
        self.read()


def tcp_pair():
    server = socket.socket()
    server.bind(('127.0.0.1', 0))
    server.listen()
    a = socket.create_connection(server.getsockname(), timeout=5)
    b, _ = server.accept()
    b.settimeout(5)
    server.close()
    return a, b


def wire(message):
    # New transport after a drop; pending sequence and session remain in cores.
    a, b = tcp_pair()
    try:
        for offset in range(0, len(message), 7):
            a.sendall(message[offset:offset + 7])
            time.sleep(0.001)
        result = b''
        while len(result) < 56:
            part = b.recv(56 - len(result))
            assert part, 'truncated TCP packet'
            result += part
        return result
    finally:
        a.close()
        b.close()


def relay(source, dest, duplicate=False):
    packets, source.pending = source.pending, []
    for data in packets:
        dest.command('packet ' + wire(data).hex())
        before = dest.rx
        if duplicate:
            dest.command('packet ' + wire(data).hex())
            assert dest.rx == before, 'duplicate was executed again'
        acknowledgements, dest.acks = dest.acks, []
        for ack in acknowledgements:
            source.command('packet ' + wire(ack).hex())


peers = []
try:
    master, slave = Peer(0), Peer(1)
    peers = [master, slave]
    relay(master, slave, True)
    slave.command('slave b9a0 280065')
    relay(slave, master)
    master.command('master b9a0')
    assert master.reg[1] == 0xb9a0, 'master did not discover slave'
    relay(master, slave)
    master.command('master 8fff')
    relay(master, slave)
    slave.command('slave b9a0 280065')
    assert slave.reg[0] == 0x8fff, 'slave did not receive master handshake'
    relay(slave, master)

    # Full 1+8 halfword frames. Sender game IO -> real serial protocol -> TCP ->
    # other core -> receiver game IO. No fabricated remote register values.
    outgoing = [0x1200 + i for i in range(8)]
    returning = [0x3400 + i for i in range(8)]
    master.command('master 0')
    for word in outgoing:
        master.command(f'master {word:x}')
    assert any(p[36] & 0x80 for p in master.pending), 'no data frame produced'

    # Disconnect halfway through a wire frame. No partial frame reaches a core.
    dropped = master.pending[0]
    a, b = tcp_pair()
    a.sendall(dropped[:19])
    a.close()
    partial = b.recv(56)
    b.close()
    assert len(partial) < 56
    master.command('pause')
    slave.command('pause')
    assert master.phase == slave.phase == 4
    time.sleep(0.08)
    master.command('resume')
    slave.command('resume')
    relay(master, slave, True)  # Retained, unacknowledged frames after reconnect.
    slave.command('slave 0 28673')
    observed = []
    for word in returning:
        slave.command(f'slave {word:x} 28673')
        observed.append(slave.reg[0])
    assert observed == outgoing, (observed, outgoing)
    relay(slave, master, True)
    master.command('master 0')
    observed = []
    for i in range(8):
        master.command('master 0')
        observed.append(master.reg[1])
    assert observed == returning, (observed, returning)
    relay(master, slave)
    for peer in peers:
        peer.command('restore')
        assert peer.phase == 6
    print('PASS: two real gpSP cores discover opposite link roles and exchange '
          '8-word Gen3 frames both ways over delayed/fragmented TCP; truncated '
          'connection, pause, retained retransmission, duplicate suppression, '
          'and independent battery/full-state recovery passed')
finally:
    for peer in peers:
        if peer.proc.poll() is None:
            peer.proc.stdin.write('quit\n')
            peer.proc.stdin.flush()
        assert peer.proc.wait(timeout=10) == 0, 'core process failed on exit'
