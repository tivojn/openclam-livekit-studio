#!/usr/bin/env python3
"""Package and verify a private appearance directory without altering its model."""
import argparse,json,sys,tempfile,zipfile,shutil
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
import appearance

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path,help='Directory containing appearance.json and runtime assets')
    parser.add_argument('--model',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    manifest=appearance.validate(json.loads((args.source/'appearance.json').read_text()))
    if args.output.exists():parser.error('Output already exists; choose a new path.')
    with tempfile.TemporaryDirectory(prefix='appearance-build-') as temporary:
        archive=Path(temporary)/'verified.oclook'
        with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
            for name in ['appearance.json',*sorted(manifest['files'])]:
                source=args.source/name
                if source.is_symlink():raise appearance.AppearanceError('Asset links are not allowed.')
                z.write(source,name)
        appearance.install(archive,Path(temporary)/'validation',args.model)
        args.output.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(archive,args.output)
    print(json.dumps({'file':str(args.output),'bytes':args.output.stat().st_size,'sha256':appearance.digest(args.output)}))
if __name__=='__main__':main()
