import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { VisionTransportPort, VisionRequestIdentity, VisionResponse, VisionFailure } from '../domain/VisionModels';
import { ParsedCancellation, ParsedAssetState } from '../domain/ParsedDocumentModels';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { VisionCredentialStore } from './VisionCredentialStore';
import { VISION_ENDPOINT, VisionLimits, visionPayload, visionDecode } from '../pipeline/VisionPolicy';

export class VisionTransportAdapter implements VisionTransportPort {
  private credentials: VisionCredentialStore; private identity: ParsedIdentityPort;
  constructor(credentials: VisionCredentialStore, identity: ParsedIdentityPort) { this.credentials=credentials; this.identity=identity; }
  async describe(input: VisionRequestIdentity, bytes: Uint8Array, cancel: ParsedCancellation, admit: (launch: () => void) => Promise<void>): Promise<VisionResponse> {
    cancel.check(); const a=input.asset;
    if (a.state!==ParsedAssetState.Ready || bytes.length!==a.bytes || bytes.length>20971520 || a.frames!==1 || a.pixelWidth<1 || a.pixelHeight<1 || a.pixelWidth*a.pixelHeight>20000000 || await this.identity.hash(bytes)!==input.imageHash || a.payloadHash!==input.imageHash) { throw new VisionFailure('ManagedImageIdentity','request'); }
    const content: string=visionPayload(a.mime,await new util.Base64Helper().encodeToString(bytes,util.Type.BASIC)); cancel.check();
    let ended: boolean=false; let active: boolean=true; let launched: boolean=false; let size: number=0; const chunks: Uint8Array[]=[];
    const timeout: rcp.Timeout={connectMs:30000,transferMs:120000,inactivityMs:30000}; const transfer: rcp.TransferConfiguration={autoRedirect:false,timeout:timeout};
    const events: rcp.HttpEventsHandler={onDataEnd:(): void=>{ended=true;}};
    const tracing: rcp.TracingConfiguration={verbose:false,collectTimeInfo:false,plaintextInException:false,httpEventsHandler:events};
    const config: rcp.Configuration={transfer:transfer,tracing:tracing}; const cache: rcp.CacheControl={noCache:true,noStore:true,keepCache:false}; const sessionConfig: rcp.SessionConfiguration={requestConfiguration:config,cacheControl:cache};
    const session: rcp.Session=rcp.createSession(sessionConfig); const request: rcp.Request=new rcp.Request(VISION_ENDPOINT,'POST'); request.content=content;
    request.destination=(buffer: ArrayBuffer): void=> { cancel.check(); if (!active || buffer.byteLength>VisionLimits.response-size) { session.cancel(request); throw new VisionFailure('ResponseBudget','response',launched); } size+=buffer.byteLength; chunks.push(new Uint8Array(buffer).slice()); };
    let timer: number=-1;
    try {
      const deadline: Promise<rcp.Response>=new Promise<rcp.Response>((_resolve: (r: rcp.Response)=>void,reject: (error: Object)=>void): void=> { timer=setTimeout((): void=> { active=false; session.cancel(request); reject(new VisionFailure('TimeoutUnknown','transport',launched)); },Math.max(1,Math.min(VisionLimits.ms,cancel.deadline-Date.now()))); });
      const response: rcp.Response=await Promise.race<rcp.Response>([this.credentials.fetch(request,session,(): void=> { cancel.check(); if (!active) { throw new VisionFailure('Canceled','transport',launched); } },async (launch: () => void): Promise<void>=> { await admit((): void=> { cancel.check(); launched=true; launch(); }); }),deadline]);
      if (response.statusCode!==200) { throw new VisionFailure(`Http:${response.statusCode}`,'transport',true); } if (!ended) { throw new VisionFailure('ResponseIncomplete','transport',true); }
      const raw: Uint8Array=new Uint8Array(size); let at: number=0; for (const c of chunks) { raw.set(c,at); at+=c.length; }
      try { return visionDecode(util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(raw)); }
      catch (error) { if (error instanceof VisionFailure) { throw error; } throw new VisionFailure('InvalidVisionResponse','response',true); }
    } catch (error) { if (error instanceof VisionFailure) { throw error; } throw new VisionFailure(launched?'NetworkOrCanceledUnknown':'NoRequestCredentialOrPolicy','transport',launched); }
    finally { active=false; if (timer>=0) { clearTimeout(timer); } request.headers=undefined; request.content=undefined; request.destination=undefined; session.close(); }
  }
}
