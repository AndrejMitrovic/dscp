# dscp

This is an implementation of SCP (Stellar Consensus Protocol) in the D2 programming language.

# Examples

There is a very old outdated commit which uses this library, found in:
https://github.com/AndrejMitrovic/agora/tree/dscp

It might be using a stale (pruned) commit however. Not guaranteed to work.

# Building

## Dependencies

A recent version of a D2 compiler. For the core library there are no 3rd party dependencies.

For testing these are the dependencies:
- `libsodium`:  For generating / verifying signatures

## Build instructions

```console
# Install a D compiler such as LDC:
curl https://dlang.org/install.sh | bash -s ldc-1.25.1

# Add the compiler to the $PATH
source ~/dlang/ldc-1.25.1/activate

# Run unittests
rdmd -g -unittest -main --compiler=ldc2 -vcolumns src/dscp/SCP.d

# Build the library
dub build

# Build and run the tests
dub test
```
