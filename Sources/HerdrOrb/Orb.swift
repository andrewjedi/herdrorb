import SwiftUI
import MetalKit

struct PearlOrb: NSViewRepresentable {
    var hovered = false
    var variant: Float = 0
    func makeNSView(context: Context) -> MTKView {
        let view = OrbMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        if let renderer = OrbRenderer(view) { context.coordinator.renderer = renderer; view.delegate = renderer }
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.hovered = hovered
        context.coordinator.renderer?.variant = variant
        (view as? OrbMetalView)?.updateActivity()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderer: OrbRenderer? }
}

final class OrbMetalView: MTKView {
    private var visibilityObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.updateActivity() }
        if accessibilityObserver == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updateActivity() }
        }
        updateActivity()
    }
    func updateActivity() {
        let visible = window?.isVisible == true && !isHiddenOrHasHiddenAncestor
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isPaused = !visible || reduceMotion
        enableSetNeedsDisplay = reduceMotion
        if reduceMotion && visible { setNeedsDisplay(bounds) }
    }
    deinit {
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}

final class OrbRenderer: NSObject, MTKViewDelegate {
    private static var pipelines: [UInt64: MTLRenderPipelineState] = [:]
    private static let pipelineLock = NSLock()
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var hovered = false
    var variant: Float = 0
    private var hoverAmount: Float = 0
    let start = Date()
    init?(_ view: MTKView) {
        guard let device = view.device, let queue = device.makeCommandQueue() else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V vertexMain(uint id [[vertex_id]]) {
            float2 p[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
            V v; v.p=float4(p[id],0,1); v.uv=p[id]; return v;
        }
        float hash(float2 p) {
            return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453);
        }
        float noise(float2 p) {
            float2 i=floor(p), f=fract(p);
            f=f*f*(3.-2.*f);
            return mix(mix(hash(i),hash(i+float2(1,0)),f.x),
                       mix(hash(i+float2(0,1)),hash(i+float2(1,1)),f.x),f.y);
        }
        float cloud(float2 p) {
            float value=0., amplitude=.55;
            for (int i=0;i<4;i++) {
                value+=amplitude*noise(p);
                p=float2(p.x*.8-p.y*.6,p.x*.6+p.y*.8)*2.1+3.7;
                amplitude*=.48;
            }
            return value;
        }
        float2 rotate(float2 p,float a) {
            return float2(cos(a)*p.x-sin(a)*p.y,sin(a)*p.x+cos(a)*p.y);
        }
        fragment float4 fragmentMain(V v [[stage_in]], constant float &time [[buffer(0)]], constant float &hover [[buffer(1)]], constant float &variant [[buffer(2)]]) {
            float2 p=v.uv;
            float r=length(p), radius=.66;
            float edge=1.-smoothstep(radius-.008,radius+.008,r);
            float z=sqrt(max(0.,1.-pow(r/radius,2.)));
            float t=time*(variant < .5 ? .85 : (variant < 1.5 ? .60 : 1.12));
            // Rotating, domain-warped nebulae keep the clouds flowing at every scale.
            float2 q=rotate(p/radius,t*.34+(1.-z)*2.8);
            float2 drift=float2(t*.27,-t*.19);
            float2 warp=float2(cloud(q*3.+drift),cloud(q*3.-drift+8.));
            float gas=cloud(q*4.2+warp*2.4+drift);
            float filaments=cloud(q*8.+warp*3.5-float2(t*.35,t*.22));
            float spiral=sin(q.y*10.+q.x*4.+gas*9.-t*1.8);
            float ribbons=pow(.5+.5*spiral,9.);
            float wisps=pow(saturate(filaments*1.65),3.);
            // A luminous Milky Way band winds through pockets of deep black space.
            float band=exp(-pow((q.y*.8+q.x*.35+(gas-.5)*.65)/.42,2.));
            float nebula=smoothstep(.27,.72,gas)*(.3+.7*band);
            float3 col=mix(float3(.006,.008,.024),float3(.32,.065,.53),nebula);
            col=mix(col,float3(.055,.32,.68),smoothstep(.38,.78,filaments)*(.3+.5*band));
            col+=float3(.25,.09,.38)*wisps*.3;
            col+=mix(float3(.12,.38,.7),float3(.55,.26,.65),gas)*ribbons*wisps*.55;
            col+=float3(.26,.3,.48)*pow(band,3.)*smoothstep(.4,.8,filaments)*.5;

            // Chrome reflections: broad silver bands plus a moving, tight light source.
            float3 normal=normalize(float3(p/radius,z));
            float3 light=normalize(float3(-.55+.3*sin(t*.9),.65+.2*cos(t*.7),1.));
            float spec=pow(saturate(dot(normal,light)),72.);
            float reflection=pow(.5+.5*sin(p.x*5.-p.y*3.+z*7.+gas*2.+t*.9),22.);
            float rim=pow(1.-z,3.);
            col*=.65+.35*z;
            col+=float3(.72,.87,1.)*reflection*.16;
            col+=float3(.86,.94,1.)*spec*.65;
            col+=mix(float3(.13,.18,.25),float3(.3,.32,.38),.5+.5*sin(t+r*8.))*rim*.4;

            // Narrow white facets and diffraction spikes sparkle over the dark nebula.
            float facet=pow(.5+.5*sin(p.x*18.+p.y*11.+z*13.+t*1.2),64.);
            col+=float3(.72,.83,1.)*facet*(.12+.3*hover)*smoothstep(.35,.7,gas);
            float2 glintCenter=float2(-.22+.07*sin(t*.9),.28+.06*cos(t*.7));
            float2 sparkle=rotate(p-glintCenter,.3);
            float flash=.65+.35*pow(.5+.5*sin(t*2.1),4.);
            float spikes=exp(-abs(sparkle.x)*180.-abs(sparkle.y)*17.)
                        +exp(-abs(sparkle.y)*180.-abs(sparkle.x)*17.);
            col+=float3(.86,.94,1.)*spikes*flash*(.9+hover);
            col+=float3(.85,.93,1.)*spec*(.55+.7*hover);

            // Tiny orbiting stars sit inside the cloud field, with softly varying sparkle.
            float2 stars=rotate(p,t*.18)*34.;
            float2 cell=floor(stars), local=fract(stars)-.5;
            float seed=hash(cell);
            float star=exp(-dot(local,local)*180.)*step(.983,seed);
            col+=float3(.7,.88,1.)*star*(.6+.4*sin(t*3.+seed*40.))*.95;

            // Each galaxy shares the animated volume but has its own light and gas palette.
            if (variant > .5 && variant < 1.5) {
                float energy=dot(col,float3(.25,.45,.30));
                col=mix(float3(.003,.025,.04),float3(.025,.65,.54),saturate(energy*2.8));
                col+=float3(.22,.60,.90)*wisps*band*.28;
                col+=float3(.62,1.,.88)*(spec*.9+star*.7+spikes*.45);
            } else if (variant > 1.5) {
                float energy=dot(col,float3(.35,.35,.30));
                col=mix(float3(.035,.003,.025),float3(.95,.075,.26),saturate(energy*3.5));
                col+=float3(1.,.43,.075)*ribbons*wisps*.65;
                col+=float3(1.,.72,.35)*pow(band,3.)*filaments*.42;
                col+=float3(1.,.88,.65)*(spec+star*.9+spikes*.65);
            }

            // Hover ignites the nebula into a white-hot, gold sun with moving plasma.
            float ignition=smoothstep(0.,1.,hover);
            float plasma=cloud(q*7.+warp*2.+float2(t*.65,-t*.5));
            float heat=smoothstep(.2,.8,plasma);
            float3 solar=mix(float3(1.,.30,.015),float3(1.,.88,.30),heat);
            solar=mix(solar,float3(1.,.98,.78),pow(z,1.5)*.8);
            solar+=float3(.14,.12,.045)*ribbons;
            if (variant > .5 && variant < 1.5) solar=mix(col,float3(.48,1.,.86),.35+.3*heat);
            else if (variant > 1.5) solar=mix(col,float3(1.,.62,.27),.35+.3*heat);
            col=mix(col,solar,ignition);

            // A violet aura expands into bright golden rays, fading before the boundary.
            float angle=atan2(p.y,p.x);
            float breath=.94+.06*sin(t*2.);
            float halo=exp(-pow((r-radius)/.15,2.))*.32*breath;
            float corona=.5+.5*sin(angle*7.-t*2.4+gas*7.);
            halo+=exp(-pow((r-radius-.035)/.10,2.))*corona*.08;
            float rays=pow(.5+.5*sin(angle*19.+t*1.8+sin(angle*7.-t)*2.),3.);
            float solarHalo=exp(-max(0.,r-radius)*8.)*(.65+.35*rays);
            solarHalo+=exp(-pow((r-radius)/.045,2.))*.4;
            halo=mix(halo,saturate(solarHalo),ignition);
            halo*=1.-smoothstep(.85,.995,r);
            float3 aura=mix(float3(.28,.10,.65),float3(.12,.38,.8),.5+.5*sin(angle*2.-t));
            float3 solarAura=mix(float3(1.,.35,.015),float3(1.,.88,.34),exp(-max(0.,r-radius)*10.));
            if (variant > .5 && variant < 1.5) {
                aura=mix(float3(.025,.4,.36),float3(.12,.48,.78),.5+.5*sin(angle*3.-t));
                solarAura=float3(.25,.9,.7);
                halo*=1.15;
            } else if (variant > 1.5) {
                aura=mix(float3(.85,.045,.27),float3(1.,.42,.08),.5+.5*sin(angle*3.-t));
                solarAura=float3(1.,.5,.16);
                halo*=1.8;
            }
            halo=saturate(halo);
            aura=mix(aura,solarAura,ignition);
            float alpha=edge+(1.-edge)*halo;
            // Premultiplied alpha preserves the luminous silhouette on any desktop.
            return float4(saturate(col)*edge+aura*halo*(1.-edge),alpha);
        }
        """
        Self.pipelineLock.lock()
        defer { Self.pipelineLock.unlock() }
        do {
            if let cached = Self.pipelines[device.registryID] { pipeline = cached }
            else {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            Self.pipelines[device.registryID] = pipeline
            }
        } catch { return nil }
        self.queue = queue
        super.init()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var time = Float(Date().timeIntervalSince(start))
        hoverAmount += ((hovered ? 1 : 0) - hoverAmount) * 0.12
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&hoverAmount, length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBytes(&variant, length: MemoryLayout<Float>.size, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
}
