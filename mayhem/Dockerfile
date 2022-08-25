# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

FROM gcr.io/oss-fuzz-base/base-builder
RUN apt-get update && apt-get install -y pkg-config make autoconf autopoint zlib1g-dev zlib1g-dev:i386 flex gawk bison
COPY . elfutils
RUN rm -rf elfutils/mayhem
WORKDIR elfutils
COPY mayhem/build.sh mayhem/*.c mayhem/*.zip $SRC/

ENV FUZZING_LANGUAGE=c++ SANITIZER=address FUZZING_ENGINE=libfuzzer ARCHITECTURE=x86_64
RUN compile
RUN chmod +x /out/fuzz-dwfl-core
