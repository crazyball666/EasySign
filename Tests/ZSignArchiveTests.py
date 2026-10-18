#!/usr/bin/env python3
"""Run: python3 Tests/ZSignArchiveTests.py (macOS, Xcode command line tools).
Compile the production ZSign archiver and round-trip Unicode names with macOS unzip.
"""
import pathlib
import subprocess
import tempfile
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[1]
SOURCE = REPO / 'EasySign/Vendor/ZSign/src'


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    with tempfile.TemporaryDirectory(prefix='easysign-archive-tests-') as temporary:
        root = pathlib.Path(temporary)
        harness = root / 'archive-test.cpp'
        harness.write_text('#include "common/archive.h"\n'
                           'int main(int argc, char** argv) {\n'
                           '  return argc == 4 && Zip::Archive(argv[1], argv[2], atoi(argv[3])) ? 0 : 1;\n'
                           '}\n')
        objects = []
        for name in ['zip', 'unzip', 'ioapi']:
            obj = root / (name + '.o')
            run('clang', '-c', SOURCE / f'third-party/minizip/{name}.c', '-o', obj)
            objects.append(obj)
        executable = root / 'archive-test'
        run('clang++', '-std=c++11', '-I', SOURCE, harness,
            *[SOURCE / f'common/{name}.cpp' for name in ['archive', 'fs', 'util', 'log']],
            *objects, '-lz', '-o', executable)
        payload = root / 'input'
        files = {
            'Payload/Eggplant.app/番糯糯新消失.json': b'{"ok":true}',
            'Payload/Eggplant.app/中文目录/动画资源.json': b'{}',
            'Payload/Eggplant.app/emoji-🍅.json': b'[]',
            'Payload/Eggplant.app/ascii.json': b'{}',
            'Payload/Eggplant.app/Eggplant': b'executable fixture',
        }
        for name, content in files.items():
            file = payload / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(content)
            file.chmod(0o755 if file.name == "Eggplant" else 0o644)
        for level in [0, 6]:
            archive = root / f'candidate-{level}.ipa'
            run(executable, payload, archive, level)
            output = root / f'verification-{level}'
            run('/usr/bin/unzip', '-o', '-q', archive, '-d', output)
            for name, content in files.items():
                restored = output / name
                assert restored.read_bytes() == content, name
                assert restored.stat().st_mode & 0o777 == (payload / name).stat().st_mode & 0o777, name
            with zipfile.ZipFile(archive) as zipped:
                for entry in zipped.infolist():
                    assert entry.create_system == 3, (entry.filename, entry.create_system)
                    assert entry.flag_bits & 0x800, (entry.filename, entry.flag_bits)
                assert zipped.testzip() is None
            print(f'PASS  Unicode file/directory names and contents survive ZSign ZIP -> unzip (level {level})')
    print('ALL PASS')


if __name__ == '__main__':
    main()
