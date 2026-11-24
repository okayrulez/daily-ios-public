import {expect,it} from 'vitest';
import {mergeDesktopConversations} from '../src/shared/desktop-conversations';
import {emptyMemory} from '../src/shared/mobile-pipeline';
import {snapshot} from './fixtures';
it('publishes only Codex sources, preserves phone data and corrections, and is idempotent',()=>{
 const phone=snapshot();const memory={...emptyMemory(),sources:phone.writings,graph:phone.graph,deadlines:phone.deadlines};
 const desktop=snapshot();desktop.writings[0]={...desktop.writings[0],id:'codex-source',kind:'conversation',importKey:'codex_thread',userEvidence:'Bugün yürüdüm.'};
 desktop.graph.nodes=[{...desktop.graph.nodes[0],id:'codex-node',key:'codex-walk',corrections:[],evidence:[{...desktop.graph.nodes[0].evidence[0],sourceId:'codex-source'}]}];desktop.graph.edges=[];
 const result=mergeDesktopConversations({memory,snapshot:desktop});
 expect(result.changed).toBe(true);expect(result.memory.sources).toHaveLength(3);
 expect(result.memory.graph.nodes.find(n=>n.id==='node-one')).toEqual(phone.graph.nodes[0]);
 expect(result.memory.deadlines).toEqual(phone.deadlines);
 expect(mergeDesktopConversations({memory:result.memory,snapshot:desktop}).changed).toBe(false);
});
it('rejects assistant-only quotations without modifying the original memory',()=>{
 const desktop=snapshot();desktop.writings[0]={...desktop.writings[0],kind:'conversation',importKey:'codex_thread',userEvidence:'Başka bir kullanıcı mesajı'};
 const memory=emptyMemory();expect(()=>mergeDesktopConversations({memory,snapshot:desktop})).toThrow();expect(memory.sources).toEqual([]);
});
