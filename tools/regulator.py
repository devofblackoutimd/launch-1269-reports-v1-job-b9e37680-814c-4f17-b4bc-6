#!/usr/bin/env python3
"""Dry-run only: print bounded Params proposals and a two-epoch event plan. No network/signing."""
import argparse, json, math
from pathlib import Path
BOUNDS={'EmissionBps':(200,600),'TariffBps':(1000,3000),'DemandTarget':(10,40),'PositiveWeight':(2000,5000)}

def propose(state):
    now=state['timestamp'];values=state['params'];last=state['lastChanged'];pool=state['availableTokens'];daily=state['dailyOutflowTokens']
    if pool<0 or daily<0: raise ValueError('token balances and outflow must be nonnegative')
    if state.get('pacePolicy','reduce') not in ('reduce','hold','adaptive'): raise ValueError('invalid pacePolicy')
    runway=pool/daily if daily>0 else (math.inf if pool>0 else 0);payback=state['medianPaybackDays'];loss=state['weeklyEventLossBps'];desired=dict(values);reason=[]
    if runway<14:
        desired['EmissionBps']=math.ceil(values['EmissionBps']*.9)
        desired['TariffBps']=math.floor(values['TariffBps']*1.1)
        desired['DemandTarget']=math.ceil(values['DemandTarget']*.9)
        reason.append('Runway below fourteen days: slow outflow and pack supply, recycle a higher tariff.')
    elif payback>10:
        desired['EmissionBps']=math.floor(values['EmissionBps']*1.1)
        # Conservative total committed daily budget includes referral, green and weekly headroom.
        desired['EmissionBps']=min(desired['EmissionBps'],int(10000/(14*1.16)))
        desired['TariffBps']=math.ceil(values['TariffBps']*.9)
        desired['DemandTarget']=max(10,values['DemandTarget']-values['DemandTarget']//10)
        reason.append('Payback above ten days with runway room: increase mining and lower electricity.')
    if runway>=14 and state.get('pacePolicy','reduce')=='hold':
        desired['DemandTarget']=values['DemandTarget']
    if runway>=14 and state.get('pacePolicy','reduce')=='adaptive' and payback>30:
        desired['DemandTarget']=min(40,values['DemandTarget']+values['DemandTarget']//10)
    if loss>800:
        desired['PositiveWeight']=math.floor(values['PositiveWeight']*1.1)
        reason.append('Event losses approach ten percent: favor positive events and reduce severity.')
    output=[]
    for key,(low,high) in BOUNDS.items():
        old=values[key];step=old//10;next_=max(low,old-step,min(high,old+step,desired[key]))
        if next_!=old:output.append(dict(key=key,current=old,proposed=next_,eligibleAt=last[key]+86400,ready=now>=last[key]+86400,letter=' '.join(reason)))
    # Network conditions/rolling counts must still be checked on-chain; the contract enforces quotas.
    kinds=['Green','Cheap'] if loss>800 or runway<14 else ['Calm','Green']
    return dict(dryRun=True,runwayDays=None if math.isinf(runway) else runway,proposals=output,
                nextTwoEpochs=[dict(epoch=state['epoch']+i+1,kind=k,severity=5000 if loss>800 else 10000,randomNumber='operator must supply before shift',letter=' '.join(reason) or 'Maintain bounded conditions.') for i,k in enumerate(kinds)],
                operatorActions=['Resolve each shifted epoch before its future block hash expires.','Process every closed epoch in batches; then permit the next shift.','Inspect TWAP, reward-pool commitments and simulated payback before signing any proposal.'])

def example():
    return dict(timestamp=172800,epoch=12,availableTokens=1_000_000,dailyOutflowTokens=80000,medianPaybackDays=15,weeklyEventLossBps=900,
        params=dict(EmissionBps=350,TariffBps=1500,DemandTarget=20,PositiveWeight=2500),lastChanged=dict(EmissionBps=0,TariffBps=0,DemandTarget=0,PositiveWeight=0))
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('state',nargs='?',type=Path);parser.add_argument('--example',action='store_true');args=parser.parse_args()
    if not args.example and args.state is None:parser.error('supply state.json or --example')
    print(json.dumps(propose(example() if args.example else json.loads(args.state.read_text())),indent=2))
