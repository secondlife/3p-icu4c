#!/usr/bin/env bash

cd "$(dirname "$0")"
top="$(pwd)"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about undefined variables
set -u

ICU4C_SOURCE_DIR="icu"
VERSION_HEADER_FILE="$ICU4C_SOURCE_DIR/source/common/unicode/uvernum.h"
VERSION_MACRO="U_ICU_VERSION"

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

dedupe_path ()
{
    # We've observed some weird failures in which the PATH is too big to be
    # passed to a child process! When that gets munged, we start seeing errors
    # like failing to understand the 'nmake' command. Thing is, by this point
    # in the script we've acquired a shocking number of duplicate entries.
    # Dedup the PATH using Python's OrderedDict, which preserves the order in
    # which you insert keys.
    # We find that some of the Visual Studio PATH entries appear both with and
    # without a trailing slash, which is pointless. Strip those off and dedup
    # what's left.
    # Pass the existing PATH as an explicit argument rather than reading it
    # from the environment to bypass the fact that cygwin implicitly converts
    # PATH to Windows form when running a native executable. Since we're
    # setting bash's PATH, leave everything in cygwin form. That means
    # splitting and rejoining on ':' rather than on os.pathsep, which on
    # Windows is ';'.
    # Use python -u, else the resulting PATH will end with a spurious '\r'.
    export PATH="$(python -u -c "import sys
from collections import OrderedDict
print(':'.join(OrderedDict((dir.rstrip('/'), 1) for dir in sys.argv[1].split(':'))))" "$PATH")"
}

stage="$(pwd)/stage"

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

pushd "$ICU4C_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            dedupe_path

            export PATH="$(python -u -c "import sys
print(':'.join(d for d in sys.argv[1].split(':')
if not any(frag in d for frag in ('CommonExtensions', 'VSPerfCollectionTools', 'Team Tools'))))" "$PATH")"

            # According to the icu build instructions for Windows,
            # runConfigureICU doesn't work for the Microsoft build tools, so
            # just use the provided .sln file.

            pushd ../icu/source
                msbuild.exe "allinone\allinone.sln" "/t:Build" "/p:Configuration=Release;Platform=$AUTOBUILD_WIN_VSPLATFORM;PlatformToolset=v143"
            popd

            mkdir -p "$stage/lib"
            mkdir -p "$stage/include"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then bitdir=./lib
            else bitdir=./lib64
            fi

            dedupe_path

            # avoid confusion with Windows find.exe, SIGH
            /usr/bin/find $bitdir -name 'icu*.lib' -print -exec cp {} $stage/lib/ \;

            cp -R include/* "$stage/include"

            # populate version_file
            cl /DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
               /DVERSION_MACRO="$VERSION_MACRO" \
               /Fo"$(cygpath -w "$stage/version.obj")" \
               /Fe"$(cygpath -w "$stage/version.exe")" \
               "$(cygpath -w "$top/version.c")"
            "$stage/version.exe" > "$stage/version.txt"
            rm "$stage"/version.{obj,exe}
        ;;
        darwin*)
            pushd "source"

                opts="-arch $AUTOBUILD_CONFIGURE_ARCH $LL_BUILD_RELEASE -DU_CHARSET_IS_UTF8=1"
                export CFLAGS="$opts"
                export CXXFLAGS="$opts"
                export LDFLAGS="$opts"
                export common_options="--prefix=${stage} --enable-shared=no \
                    --enable-static=yes --disable-dyload --enable-extras=no \
                    --enable-samples=no --enable-tests=no --enable-layout=no"
                mkdir -p $stage
                chmod +x runConfigureICU configure install-sh
                # HACK: Break format layout so boost can find the library.
                ./runConfigureICU MacOSX $common_options --libdir=${stage}/lib/

                make -j2
                make install
            popd

            # populate version_file
            cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
               -DVERSION_MACRO="$VERSION_MACRO" \
               -o "$stage/version" "$top/version.c"
            "$stage/version" > "$stage/version.txt"
            rm "$stage/version"
        ;;
        linux*)
            pushd "source"
                ## export CC="gcc-4.1"
                ## export CXX="g++-4.1"
                export CFLAGS="-m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE"
                export CXXFLAGS="$CFLAGS"
                export common_options="--prefix=${stage} --enable-shared=no \
                    --enable-static=yes --disable-dyload --enable-extras=no \
                    --enable-samples=no --enable-tests=no --enable-layout=no"
                mkdir -p $stage
                chmod +x runConfigureICU configure install-sh
                # HACK: Break format layout so boost can find the library.
                ./runConfigureICU Linux $common_options --libdir=${stage}/lib/

                make -j2
                make install
            popd

            # populate version_file
            cc -DVERSION_HEADER_FILE="\"$VERSION_HEADER_FILE\"" \
               -DVERSION_MACRO="$VERSION_MACRO" \
               -o "$stage/version" "$top/version.c"
            "$stage/version" > "$stage/version.txt"
            rm "$stage/version"
        ;;
    esac
    mkdir -p "$stage/LICENSES"
	sed -e 's/<[^>][^>]*>//g' -e '/^ *$/d' license.html >"$stage/LICENSES/icu.txt"
	cp unicode-license.txt "$stage/LICENSES/"
popd
