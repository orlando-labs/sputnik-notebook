#!/usr/bin/env python3
from pathlib import Path
import collections,json,os,subprocess,sys,time
ROOT=Path('/home/slowpilot/sputnik-remote-core')
RELEASE=Path('/home/slowpilot/sputnik-releases/20261031-current-c17d12b')
before='--before' in sys.argv
def sample():
 out={}
 for mode in ['agent','gateway']:
  pid=int((ROOT/(mode+'.pid')).read_text());p=Path('/proc')/str(pid)
  status=dict(l.split(':',1) for l in (p/'status').read_text().splitlines() if ':' in l)
  maps=dict(l.split(':',1) for l in (p/'smaps_rollup').read_text().splitlines() if ':' in l)
  fields=(p/'stat').read_text().split(') ',1)[1].split()
  waits=collections.Counter((t/'wchan').read_text().strip() for t in (p/'task').iterdir())
  env=dict(x.decode().split('=',1) for x in (p/'environ').read_bytes().split(b'\0') if b'=' in x)
  out[mode]={'pid':pid,'exe':os.readlink(p/'exe'),'threads':int(status['Threads']),'vsz_kib':int(status['VmSize'].split()[0]),'rss_kib':int(maps['Rss'].split()[0]),'pss_kib':int(maps['Pss'].split()[0]),'swap_kib':int(maps['Swap'].split()[0]),'cpu_ticks':int(fields[11])+int(fields[12]),'waits':dict(waits),'limits':{k:v for k,v in env.items() if k in ['SPUTNIK_TASK_MAX_THREADS','SPUTNIK_FFI_MAX_THREADS']}}
 return out
start=sample()
if before:
 report={'processes':start}
 name='before-resources.json'
else:
 time.sleep(10);end=sample()
 for mode in end:
  if end[mode]['exe']!=str(RELEASE/'sputnik-notebook-remote'):raise RuntimeError('unexpected executable')
  end[mode]['cpu_percent_one_core']=round((end[mode]['cpu_ticks']-start[mode]['cpu_ticks'])/os.sysconf('SC_CLK_TCK')/10*100,2)
  end[mode]['threads_start']=start[mode]['threads']
 command='/home/slowpilot/.local/bin/sputnik'
 version=subprocess.run([command,'--version'],text=True,capture_output=True,check=True,timeout=10).stdout.strip()
 if version!='sputnik 1.0.0':raise RuntimeError('CLI is not the current version')
 probe=RELEASE/'runtime-probe.s';probe.write_text('print(40 + 2)\n')
 result=subprocess.run([command,'run',str(probe)],text=True,capture_output=True,check=True,timeout=30).stdout.strip()
 if result!='42':raise RuntimeError('CLI runtime probe failed')
 report={'processes':end,'cli_version':version,'cli_runtime_probe':result,'current':str((ROOT/'current').resolve())}
 name='after-resources.json'
report['total_pss_kib']=sum(p['pss_kib'] for p in report['processes'].values())
(RELEASE/name).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
