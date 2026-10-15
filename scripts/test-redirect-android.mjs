import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { delimiter, join, resolve } from 'node:path';

// Dedicated local SDK/JDK paths are optional; CI uses setup-java and Maven.
const javaHome = process.env.REDIRECT_JAVA_HOME || process.env.JAVA_HOME;
const maven = process.env.REDIRECT_MAVEN_BIN || 'mvn';
const env = { ...process.env, ...(javaHome ? { JAVA_HOME: javaHome } : {}) };
const sdk = resolve('sdk/redirects/android');
execFileSync(
  maven,
  [
    '-B',
    '-ntp',
    '-f',
    join(sdk, 'pom.xml'),
    'test-compile',
    'dependency:build-classpath',
    '-Dmdep.outputFile=target/contract-classpath.txt',
  ],
  { env, stdio: 'inherit', timeout: 240000 },
);
const dependencies = readFileSync(join(sdk, 'target/contract-classpath.txt'), 'utf8').trim();
const classpath = [
  join(sdk, 'target/classes'),
  join(sdk, 'target/test-classes'),
  dependencies,
].join(delimiter);
execFileSync(
  javaHome ? join(javaHome, 'bin/java') : 'java',
  ['-cp', classpath, 'guide.queer.redirects.ContractTests'],
  { env, stdio: 'inherit', timeout: 70000 },
);
