// Owner-controlled coordinator. No automatic installation or recovery at boot.
import * as fs from 'fs';
import { open_protocol, decode_record } from './protocol.uc';
import { open_io } from './state.uc';
const SERIES='/etc/home-gateway-owner-series',D='/etc/home-gateway-deploy',LOCK='/tmp/home-gateway-deploy.lock';
const ACCEPTED='d2039b6c62da3aa458f720af1c46fb619aee48dd';
const V1TX='tx.u'+substr(ACCEPTED,0,24);
const STAGES=['preflight','apply','verify','rollback','recover'];
function need(ok,why){if(!ok)die('OWNER_SERIES_ENGINE_'+why);}
function quote(s){return "'"+replace(s,"'","'\\''")+"'";}
function opid(id){return type(id)=='string' && match(id,/^tx\.[0-9a-f]{32}$/)!=null;}
function txid(id){return type(id)=='string' && match(id,/^tx\.[A-Za-z0-9]{1,32}$/)!=null;}
function sha(value){return type(value)=='string' && match(value,/^[0-9a-f]{64}$/)!=null;}
function commit(value){return type(value)=='string' && match(value,/^[0-9a-f]{40}$/)!=null;}
function encode(value){return sprintf('%J\n',value);}

export function describe_operation(kind,id,m,selected,pin) {
    need(index(['APPLY','ROLLBACK'],kind)>=0 && opid(id) && sha(pin),'IDENTITY');
    need(type(selected)=='object' && txid(selected.transaction) && commit(selected.source) &&
        (selected.generation=='V1' || opid(selected.generation)) && commit(m.source_commit) && commit(m.baseline_commit),'SELECTION');
    let apply=kind=='APPLY';
    need(selected.source==(apply?m.baseline_commit:m.source_commit),'BASELINE_MISMATCH');
    if(!apply)need(opid(selected.generation) && (selected.parent_generation=='V1' || opid(selected.parent_generation)) &&
        txid(selected.parent_transaction),'ROLLBACK_PARENT');
    return {format:'HG_OWNER_SERIES_OPERATION_V1',id,kind,kit_pin:pin,source_commit:m.source_commit,
        baseline_commit:m.baseline_commit,before_generation:selected.generation,before_transaction:selected.transaction,
        before_source:selected.source,after_generation:apply?id:selected.parent_generation,
        after_transaction:apply?id:selected.parent_transaction,after_source:apply?m.source_commit:m.baseline_commit};
};
