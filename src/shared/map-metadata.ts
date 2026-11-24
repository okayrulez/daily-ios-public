import {z} from 'zod';

export const MapQualityDimensions=z.object({
  coverage:z.number().int().min(0).max(100),evidence:z.number().int().min(0).max(100),
  coherence:z.number().int().min(0).max(100),distinctness:z.number().int().min(0).max(100),
}).strict();
const qualityExplanation={dimensions:MapQualityDimensions,rationale:z.string().min(1).max(1600),
  strengths:z.array(z.string().min(1).max(500)).max(4),gaps:z.array(z.string().min(1).max(500)).max(4)};
export const MapQualitySchema=z.object({...qualityExplanation,percent:z.number().int().min(0).max(100),
  reviewedNodes:z.number().int().positive(),totalNodes:z.number().int().positive(),scope:z.enum(['full','partial']),
  fingerprint:z.string().regex(/^[a-f0-9]{64}$/),assessedAt:z.string(),
}).strict().refine(q=>q.reviewedNodes<=q.totalNodes&&(q.scope!=='full'||q.reviewedNodes===q.totalNodes),
  'Invalid map assessment coverage');

export const MapIdentitySchema=z.object({
  id:z.string().min(1).max(500), title:z.string().min(1).max(180),
  aliases:z.array(z.string().min(1).max(180)).max(30),
  description:z.string().trim().min(1).max(500).optional(),
  descriptionFingerprint:z.string().regex(/^[a-f0-9]{64}$/).optional(),
  descriptionSource:z.enum(['analysis','local']).optional(),
  quality:MapQualitySchema.optional(),
}).strict();
// Optional for compatibility with saved analyses and older remote prompt revisions.
export const MapSummaryProposals=z.array(z.object({
  map_id:z.string().max(500).nullish(),title:z.string().trim().min(1).max(180),
  summary:z.string().trim().min(1).max(500),
}).strict());
/** Preserve every segment's maps; latest wording leads when the same map recurs. */
export function mergeMapSummaryProposals(rows:z.infer<typeof MapSummaryProposals>) {
  const groups=new Map<string,typeof rows>();
  for(const row of rows) {
    const key=row.map_id||row.title.normalize('NFKC').toLocaleLowerCase('tr').replace(/\s+/g,' ').trim();
    groups.set(key,[...(groups.get(key)??[]),row]);
  }
  return [...groups.values()].map(group=>{
    const summary=[...new Set(group.map(s=>s.summary).reverse())].join(' ');
    return {...group.at(-1)!,summary:summary.length<=500?summary:summary.slice(0,499)+'…'};
  });
}
export const MapReviewReportSchema=z.object({
  assessments:z.array(z.object({map_id:z.string().min(1).max(500),
    node_ids:z.array(z.string().min(1).max(500)).min(1).max(32),...qualityExplanation}).strict()).max(32).optional(),
  summary:z.string().min(1).max(3000),
  findings:z.array(z.object({
    kind:z.enum(['duplicate','misplaced','weak_connection','missing_connection','unclear_title','useful','coverage']),
    map_ids:z.array(z.string().min(1).max(500)).max(12),
    node_ids:z.array(z.string().min(1).max(500)).max(12),
    explanation:z.string().min(1).max(2000),
    recommendation:z.string().min(1).max(2000),
  }).strict()).max(12),
}).strict();
export const MapReviewStateSchema=z.object({
  journalIds:z.array(z.string().min(1).max(100)),
  lastAttemptCount:z.number().int().nonnegative(),
  status:z.enum(['waiting','complete','failed']),
  reviewedFingerprints:z.record(z.string(),z.string()),
  report:MapReviewReportSchema.optional(),
  completedAt:z.string().optional(),
}).strict();
