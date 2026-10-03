"""Bound one owned diagnostic command; never select or kill unrelated tasks."""
import datetime,subprocess,sys
seconds=int(sys.argv[1]);command=sys.argv[2:]
assert seconds>0 and command
print(datetime.datetime.now(datetime.timezone.utc).isoformat(), 'Diagnostic command:',command[0],flush=True)
try:
    result=subprocess.run(command,timeout=seconds)
except subprocess.TimeoutExpired:
    print('Owned diagnostic command exceeded its limit:',seconds,'seconds',file=sys.stderr,flush=True)
    raise SystemExit(124)
raise SystemExit(result.returncode)
