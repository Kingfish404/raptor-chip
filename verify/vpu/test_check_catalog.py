#!/usr/bin/env python3
"""Negative checks against isolated catalog evidence copies."""
from pathlib import Path
import re
import shutil
import tempfile
from check_catalog import audit, ROOT

source=ROOT/'verify/build/vpu/core-top-64-128-64-64-2-opt1-spike-catalog'
audit(source)
for mutation in ('missing_variant','no_execution','missing_completion'):
    with tempfile.TemporaryDirectory(prefix='vpu-catalog-',dir='/tmp') as temp:
        directory=Path(temp)
        shutil.copyfile(source/'sources.json',directory/'sources.json')
        shutil.copyfile(source/'reference.json',directory/'reference.json')
        log=(source/'run.log').read_text()
        if mutation=='missing_variant':
            log=re.sub(r'^CATALOG .+\n','',log,count=1,flags=re.M)
        elif mutation=='no_execution':
            def replace(match):
                return match[1]+'0 illegal='+str(int(match[2])+int(match[3]))
            log=re.sub(r'(^CATALOG name=\S+ nf=\d+ accepted=)(\d+) illegal=(\d+)',
                       replace,log,count=1,flags=re.M)
        else:log=re.sub(r'^PASS catalog_top .+\n','',log,flags=re.M)
        (directory/'run.log').write_text(log)
        try:audit(directory)
        except ValueError as error:print('PASS rejected',mutation,':',error)
        else:raise RuntimeError('Accepted invalid catalog evidence: '+mutation)
