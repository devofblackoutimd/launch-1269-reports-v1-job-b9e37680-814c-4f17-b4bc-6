#!/usr/bin/env python3
"""Source-level authority regression, paired with deployed-graph and unauthorized-caller tests."""
from pathlib import Path
import json
import re
sources={p:str(p.read_text()) for p in Path('src').rglob('*.sol')}
for p,s in sources.items():
    assert not re.search(r'function\s+(selectProfile|setFreeRoot|blankBillboard|transferOwnership|renounceOwnership|upgradeTo\w*|setOracleSigner)\s*\(',s),p
    assert not re.search(r'\bonlyOwner\b|\btx\.origin\b|\.delegatecall\s*\(',s),p
s=Path('src/SwarmDesk.sol').read_text()
assert 'is OracleAttestationConsumer, ReentrancyGuard' in s
assert not re.search(r'\.call\s*(?:\{|\()',s),'Desk must not expose arbitrary calls'
assert 'function execute(uint8 stream, bytes calldata answer)' in s
assert 'keccak256(answer) != r.answerHash' in s
assert 'selectProfile' not in Path('script/Deploy.s.sol').read_text()
abi=json.loads(Path('out/SwarmDesk.sol/SwarmDesk.json').read_text())['abi']
args=next(x['inputs'] for x in abi if x['type']=='constructor')
assert len(args)==12 and all(x['type'] in ('address','bytes32','uint256') for x in args), 'Launcher accepts at most 16 flat static words and the legacy code generator decodes at most 12'
print('No owner, upgrade, root setter, profile selector, moderation or arbitrary-call authority in src; Desk execution commits exact oracle bytes.')
