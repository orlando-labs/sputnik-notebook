from pathlib import Path
import os,datetime,json,shutil
base=Path('/home/slowpilot/sputnik-remote-core');release=(base/'current').resolve(strict=True)
binary_dir=Path('/home/slowpilot/.local/bin');binary_dir.mkdir(parents=True,exist_ok=True)
backup=base/'backups'/('cli-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'));backup.mkdir(parents=True,mode=0o700)
installed={}
for name,relative in [('sputnik','src/sputnik-lang/build/sputnik'),('isputnik','src/sputnik-lang/build/isputnik'),('sputnik-notebook-remote','sputnik-notebook-remote')]:
    assert os.access(release/relative,os.X_OK)
    target=binary_dir/name
    if target.exists() or target.is_symlink():
        if target.is_symlink():(backup/(name+'.symlink')).write_text(os.readlink(target)+'\n')
        else:shutil.copy2(target,backup/name)
    staged=binary_dir/(name+'.next.'+str(os.getpid()))
    staged.write_text('#!/bin/sh\nset -eu\n. '+str(base/'current/env.sh')+'\nexec '+str(base/'current'/relative)+' "$@"\n')
    staged.chmod(0o755);os.replace(staged,target);installed[name]=str(target)
print(json.dumps({'release':str(release),'installed':installed}))
