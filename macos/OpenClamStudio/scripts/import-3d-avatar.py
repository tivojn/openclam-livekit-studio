"""Register a prepared .glb as an OpenClam 3D avatar without the Settings UI.

    .venv/bin/python scripts/import-3d-avatar.py ~/Desktop/tia.glb --name Tia [--activate]

Runs against the same avatar root as the app (``OPENCLAM_DATA_DIR`` or the
project directory).  Quit OpenClam Studio first when using ``--activate`` so
the app picks the new active avatar up on its next launch; without it, the
avatar simply appears in the Settings deck ready to activate.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(PROJECT, "server"))
sys.path.insert(0, PROJECT)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model", help="binary glTF (.glb) with facial shape keys")
    parser.add_argument("--name", default="", help="display name (defaults to the file name)")
    parser.add_argument("--activate", action="store_true",
                        help="make it the active desk avatar")
    args = parser.parse_args()

    import avatar3d
    from studio import build

    try:
        manifest = avatar3d.create_avatar(
            os.path.abspath(args.model), args.name, original_name=args.model)
    except avatar3d.ModelError as error:
        print(f"rejected: {error}", file=sys.stderr)
        return 2
    coverage = manifest["viseme_coverage"]
    print(f"imported {manifest['name']} as {manifest['slug']}")
    print(f"  visemes from the model: {len(coverage['direct'])}/15"
          f"{'  approximated: ' + ', '.join(coverage['recipe']) if len(coverage['recipe']) > 1 else ''}"
          f"{'  missing: ' + ', '.join(coverage['missing']) if coverage['missing'] else ''}")
    print(f"  blink: {'yes' if coverage['blink'] else 'no'}"
          f"  bones: {manifest['joint_count']}  size: {manifest['model_bytes'] / 1e6:.1f} MB")
    for warning in manifest.get("warnings") or []:
        print(f"  warning: {warning}")
    if args.activate:
        build.set_active(manifest["slug"])
        print("  activated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
