#!/usr/bin/env bash

#
# Copyright (c) 2024 Broadcom.
# The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
#
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Contributors:
#    Broadcom, Inc. - initial API and implementation
#

# Fail script if any command fails
set -e
# Echo commands as they are executed for better understanding
set -x

# Compile language server and dialect jars
cd server
mvn clean package --no-transfer-progress -Dmaven.test.skip
cd -

# Copy jars
cp server/dialect-daco/target/dialect-daco.jar clients/daco-dialect-support/server/jar
cp server/dialect-idms/target/dialect-idms.jar clients/idms-dialect-support/server/jar
cp server/engine/target/server.jar clients/cobol-lsp-vscode-extension/server/jar

# Build native image if GraalVM Native Image is available
if command -v native-image >/dev/null 2>&1 || [ -x "${GRAALVM_HOME}/bin/native-image" ] || [ -x "${JAVA_HOME}/bin/native-image" ]; then
  echo "Building native image..."
  cd server
  # Generate assisted configuration for GraalVM native build (produces reflection metadata)
  echo "Generating GraalVM assisted configuration via agent (engine module)..."
  mvn -e -B -pl engine -am -Pnative -DskipNativeTests -Dagent=true -Dtest=\!PositiveTest -Dsurefire.failIfNoSpecifiedTests=false test || true

  # Copy generated native configuration into resources (ignore if not generated)
  if [ -d engine/target/native/agent-output/test ]; then
    echo "Staging native configuration into resources..."
    mkdir -p engine/src/main/resources/META-INF/native-image
    cp -rp engine/target/native/agent-output/test/session-* engine/src/main/resources/META-INF/native-image/ || true
    # Remove JNI config produced by agent, aligns with CI behavior
    rm -f engine/src/main/resources/META-INF/native-image/session-*/jni-config.json || true
  else
    echo "Assisted native configuration not found; proceeding without it."
  fi

  # Fallback: run the server jar under the agent to record configs
  if [ ! -d engine/target/native/agent-output/test ]; then
    if [ -f engine/target/server.jar ]; then
      echo "Running JVM with native-image-agent to record reflection config (fallback)..."
      # Ensure output dir exists to avoid agent warnings
      mkdir -p engine/target/native/agent-output/run
      # Run briefly to initialize injector and record configs
      timeout ${NATIVE_AGENT_TIMEOUT:-60}s java -DserverType=NATIVE -agentlib:native-image-agent=config-merge-dir=engine/target/native/agent-output/run,config-write-period-secs=5 -jar engine/target/server.jar pipeEnabled || true
      if [ -d engine/target/native/agent-output/run ]; then
        echo "Staging runtime-generated native configuration..."
        mkdir -p engine/src/main/resources/META-INF/native-image/session-run
        # copy both flat files and any session-* that agent might emit
        cp -f engine/target/native/agent-output/run/*.json engine/src/main/resources/META-INF/native-image/session-run/ 2>/dev/null || true
        cp -rp engine/target/native/agent-output/run/session-* engine/src/main/resources/META-INF/native-image/ 2>/dev/null || true
        rm -f engine/src/main/resources/META-INF/native-image/session-*/jni-config.json || true
      else
        echo "No runtime agent output generated."
      fi
    else
      echo "Server jar not found; cannot run agent fallback."
    fi
  fi

  # Prefer musl static build on Linux if toolchain is available
  if [ "$(uname)" = "Linux" ] && command -v x86_64-linux-musl-gcc >/dev/null 2>&1; then
    mvn -e -B -Plinux-native -Dmaven.test.skip=true clean package
  else
    mvn -e -B -Pnative -Dmaven.test.skip=true clean package
  fi
  cd -

  # Copy native binary into the extension with OS-specific naming
  OS_NAME=$(uname)
  if [[ "$OS_NAME" == "Linux" ]]; then
    if [ -f server/engine/target/engine ]; then
      cp -p server/engine/target/engine clients/cobol-lsp-vscode-extension/server/native/server-linux
      chmod +x clients/cobol-lsp-vscode-extension/server/native/server-linux
    else
      echo "Native Linux engine not found at server/engine/target/engine"
    fi
  elif [[ "$OS_NAME" == "Darwin" ]]; then
    if [ -f server/engine/target/engine ]; then
      cp -p server/engine/target/engine clients/cobol-lsp-vscode-extension/server/native/server-mac
      chmod +x clients/cobol-lsp-vscode-extension/server/native/server-mac
    else
      echo "Native macOS engine not found at server/engine/target/engine"
    fi
  else
    # Windows (Git Bash / MSYS) or other environments
    if [ -f server/engine/target/engine.exe ]; then
      cp -p server/engine/target/engine.exe clients/cobol-lsp-vscode-extension/server/native/
    else
      echo "Native Windows engine not found at server/engine/target/engine.exe"
    fi
  fi
else
  echo "GraalVM native-image tool not found. Skipping native build."
  echo "Ensure GraalVM is installed and native-image is available in PATH or under \$GRAALVM_HOME/bin or \$JAVA_HOME/bin."
fi

# Compile dialect api
cd clients/cobol-dialect-api
npm ci
npm run compile
cd -

# Compile analysis package
cd clients/analysis
npm ci
npm run compile
cd -

# Build COBOL LS extension
cd clients/cobol-lsp-vscode-extension
npm ci
npm run package
cd -

# Build IMDS LS extension
cd clients/idms-dialect-support
npm ci
npm run package
cd -

# Build DACO LS extension
cd clients/daco-dialect-support
npm ci
npm run package
cd -

# Build COBOL LS Web extension
cd clients/cobol-lsp-vscode-extension
npm ci
npm run build:web
cd -

# Done
echo "Done building COBOL LS"
