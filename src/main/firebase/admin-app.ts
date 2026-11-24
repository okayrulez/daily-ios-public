import { applicationDefault, getApp, getApps, initializeApp } from 'firebase-admin/app';
import { getFirestore, type Firestore } from 'firebase-admin/firestore';

export interface FirebaseAdminConfig {
  projectId: string;
}

export function resolveFirebaseAdminConfig(env: NodeJS.ProcessEnv): FirebaseAdminConfig {
  if (env.DAILYX_FIREBASE_SERVICE_ACCOUNT_JSON?.trim()) {
    throw new Error('Embedded Firebase service-account JSON is not allowed. Use Application Default Credentials.');
  }
  const projectId = env.DAILYX_FIREBASE_PROJECT_ID?.trim();
  if (!projectId) throw new Error('Firebase project id is required. Set DAILYX_FIREBASE_PROJECT_ID.');
  if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/u.test(projectId)) {
    throw new Error('Firebase project id format is invalid.');
  }
  return { projectId };
}

export function createAdminFirestore(env: NodeJS.ProcessEnv = process.env): Firestore {
  const config = resolveFirebaseAdminConfig(env);
  const appName = 'dailyx-push-worker';
  const app = getApps().some((candidate) => candidate.name === appName)
    ? getApp(appName)
    : initializeApp({
      projectId: config.projectId,
      credential: applicationDefault(),
    }, appName);
  return getFirestore(app);
}
