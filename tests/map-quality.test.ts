import {describe,it,expect} from 'vitest';
import {emptyMemory} from '../src/shared/mobile-pipeline.js';
import {acceptMapReview,reviewContext} from '../src/shared/map-review.js';
import {refreshMapDescriptions} from '../src/shared/map-descriptions.js';
import {mapCatalog} from '../src/shared/map-registry.js';
import {exportPortableMemory} from '../src/main/memory/portable-memory-export.js';
import {snapshot} from './fixtures.js';
import {mobileAtlasRecords} from '../src/main/memory/mobile-atlas.js';
import {invoke} from '../src/shared/mobile-analysis-core.js';

function memory(){const m=exportPortableMemory(snapshot(),1);m.graph.nodes[0].corrections=[];m.graph.nodes[0].status='candidate';
  m.mapReview={journalIds:[],lastAttemptCount:0,status:'waiting',reviewedFingerprints:{}};return refreshMapDescriptions(m);}
const dimensions={coverage:80,evidence:90,coherence:70,distinctness:60};
const report=(id:string,node_ids:string[])=>({summary:'Harita incelendi.',findings:[],assessments:[{map_id:id,node_ids,
  dimensions,rationale:'Kaynaklar mevcut, bazı konular arasında açıklayıcı bağlar eksik.',strengths:['Tarihli kaynaklar'],gaps:['Bağların gerekçelerini genişlet.']}]});
const index=(m:ReturnType<typeof memory>)=>JSON.parse(JSON.parse(mobileAtlasRecords(m.graph,m).at(-1)!.content));
describe('grounded map quality assessments',()=>{
  it('retains unaffected map scores when a supported deletion command republishes the atlas',()=>{
    const m=memory();delete m.graph.nodes[1].inference;m.graph.nodes[1].mapId='map:other';m.graph.nodes[1].topicPath=['Diğer'];
    m.graph.edges=[];
    const reviewed=acceptMapReview(refreshMapDescriptions(m),report('map:other',['node-two']),['node-two']);
    const removed=JSON.parse(invoke('removeMapNode',JSON.stringify({memory:reviewed,id:'node-one'})));
    const atlas=JSON.parse(JSON.parse(removed.atlas.at(-1).content));
    expect(atlas.maps.find((map:any)=>map.title==='Diğer').quality).toMatchObject({percent:78,current:true});
  });
  it('publishes a rubric score only after a referenced AI assessment, without deriving it from node density',()=>{
    const m=memory(),id=mapCatalog(m)[0].id,ids=m.graph.nodes.map(n=>n.id);
    expect(index(m).maps[0].quality).toBeUndefined();
    const reviewed=acceptMapReview(m,report(id,ids),ids);
    const quality=index(reviewed).maps[0].quality;
    expect(quality.percent).toBe(78);
    expect(quality).toMatchObject({current:true,scope:'full',reviewedNodes:2,totalNodes:2,dimensions});
    expect(quality.rationale).toContain('Kaynaklar');
    expect(index(reviewed).maps[0].nodeCount).toBe(2);
  });
  it('labels partial assessment coverage and invalidates its currency on graph changes',()=>{
    const m=memory(),id=mapCatalog(m)[0].id;
    const reviewed=acceptMapReview(m,report(id,['node-one']),['node-one']);
    expect(index(reviewed).maps[0].quality).toMatchObject({scope:'partial',reviewedNodes:1,totalNodes:2,current:true});
    reviewed.graph.nodes[0].label='Değişen not';
    expect(index(reviewed).maps[0].quality.current).toBe(false);
  });
  it('rejects fabricated and cross-map quality evidence or unselected inspection claims',()=>{
    const m=memory(),id=mapCatalog(m)[0].id;
    expect(()=>acceptMapReview(m,report('invented',['node-one']),['node-one'])).toThrow();
    expect(()=>acceptMapReview(m,report(id,['node-two']),['node-one'])).toThrow();
    const context=reviewContext(m,['node-one']);
    expect(context.qualityScope[0]).toMatchObject({map_id:id,totalNodes:2,selectedNodeIDs:['node-one']});
    expect(index(emptyMemory() as ReturnType<typeof memory>).maps).toEqual([]);
  });
});
