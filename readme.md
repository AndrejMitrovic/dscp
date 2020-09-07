# dscp

This is an implementation of SCP (Stellar Consensus Protocol) in the D2 programming language.

# Building

## Dependencies

A recent version of a D2 compiler. For the core library there are no 3rd party dependencies.

For testing these are the dependencies:
- `libsodium`:  For generating / verifying signatures

## Build instructions

```console
# Install a D compiler such as LDC:
curl https://dlang.org/install.sh | bash -s ldc-1.20.0

# Add the compiler to the $PATH
source ~/dlang/ldc-1.20.0/activate

# Run unittests
rdmd -g -unittest -main --compiler=ldc2 -vcolumns src/dscp/SCP.d

# Build the library
dub build

# Build and run the tests
dub test
```
