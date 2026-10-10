# Panel launch adaptation

Implemented the two missing application contracts according to README.md. The
existing configuration, dependencies, art, data contracts and acceptance tests
are unchanged.

## Changes and reasons

- `src/PanelDesigns.sol`: adds the required per-wallet `designOf` mapping,
  caller-only set/clear operations with `DesignSet` events, and ordered batch
  reads. It has a nonpayable, implicit no-argument constructor and no privileged
  role. This restores the missing design registry without interpreting designs
  or requiring seat ownership.
- `src/PanelRenderer.sol`: adds the two specified interfaces and renderer API.
  Its nonpayable constructor stores seven static arguments in immutables and
  reads no dependencies, allowing the launch factory's empty-chain rehearsal.
  Script reads check all four chunks in order, copy their bytes after offset 1,
  and verify the expected hash on every read. Owner reads use bounded 32-byte
  STATICCALL output, accept only successful responses of at least 32 bytes with
  clean address words, and pack exactly 2,000 addresses. Invalid replies become
  zero seats. The HTML follows the exact template, with lowercase fixed-width
  hex, decimal chain ID and standard padded base64. The encoder reads no bytes
  past the input tail; its main loop is inline to keep rendering gas bounded.
  All helpers are private, and the renderer has no storage or linked libraries.
- `ADAPTATION.md`: records the implementation, audit disposition, validation and
  deployment handoff required by this assignment.

Neither application adds an owner, admin, fee, pause, token, initialization step,
fallback, receive function, proxy or upgrade path.

## Imported audit findings

- `2001907595d0fe06a05fe534335b849d9229d310068a15ac7b72dae54c368207`
  reproduced before changes: `forge build` failed with ParserError 6275 for the
  two missing source files. Implementing them fixes it. All original tests now
  pass, and the supplied artifact-based deployment proof also passes locally
  from `test/scratch/PanelContractsMissing.t.sol`, using the exact launch
  arguments on an empty chain.
- `9a1b52adafdac9ff7a23c3ea64915f9fab393bb88d933d24227c40c4f6613c37`
  was an implementation warning, not a defect in the original tree: there was
  no encoder to audit. A scratch regression reproduced the described algorithm's
  error by putting dirty bytes after a 40,000-byte input: the final meaningful
  base64 character became `2` instead of `w`. The implemented encoder zero-fills
  partial groups using only real input bytes. The unchanged template fuzz tests
  verify both the 40,000-byte owner snapshot and the 87,700-byte published script
  against Foundry's independent base64 encoder.

## Validation

`forge build && forge test -vv` succeeds with the original Foundry configuration:
26 unchanged project tests plus 5 supplementary scratch tests, all passing.
Scratch checks cover the supplied deployment proof, the dirty-tail reproducer,
script base64 boundary lengths, repeated script validation after dependency
changes, and the protected floor's opcode walk using the exact mainnet arguments.
Scratch tests are temporary and are not part of the submission.

The original tests measure:

- Combined application deployment: **1,332,637 gas**, below 14,000,000.
- `panelOf` with cold storage-backed owners: **14,797,827 gas**, below 30,000,000.
- ABI-encoded page response: **170,880 bytes**.

The original API, storage-layout and opcode checks all pass. No dependency was
installed. Slither was unavailable; neither Slither nor Mythril was run, and no
result from either analyzer is claimed. Foundry's lint hints were reviewed: constructor
validation is intentionally deferred, locals default to zero, decimal digits
fit in one byte, ordered chunk errors are required, and base64 length uses
intentional ceiling division.

## Deployment handoff

The launcher deploys `PanelDesigns` first with no arguments, then `PanelRenderer`
with these constructor arguments in order:

1. `seats_`: `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D`
2. `designs_`: the newly deployed `PanelDesigns` address
3. `c0`: `0xFc016403Ea7DAEA4582936E1c8D8D709E17593ab`
4. `c1`: `0x0CE16147f1e69D151252f000e8Be3647a120c897`
5. `c2`: `0x8E604EeBBC9D49e919b7D3de8534018a87292bE0`
6. `c3`: `0xCB8Ecec7902E55A62C34de38c950a907851ae298`
7. `expectedHash`: `0xd2c66890e2d2dc456f117c14ff12435ffc6fa56b73ab7955f0d838d8ae76cb76`

The existing PanelCode addresses are supplied unchanged; the launcher must not
redeploy those contracts. Verification here was local, with no mainnet broadcast.
Manifest creation and the mainnet transaction belong to the following launch
steps; this submission contains no `launch.json`.
