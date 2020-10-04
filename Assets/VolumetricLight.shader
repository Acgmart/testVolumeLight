Shader "Sandbox/VolumetricLight"
{
	Properties
	{
		[HideInInspector]_MainTex ("Texture", 2D) = "white" {}
		[HideInInspector]_ZTest ("ZTest", Float) = 0
		[HideInInspector]_LightColor("_LightColor", Color) = (1,1,1,1)
	}
	SubShader
	{
		Tags { "RenderType"="Opaque" }
		LOD 100

		CGINCLUDE
		
		#include "UnityCG.cginc"
		#include "UnityDeferredLibrary.cginc"

		sampler3D _NoiseTexture;
		sampler2D _DitherTexture;
		
		float4 _FrustumCorners[4];

		struct appdata
		{
			float4 vertex : POSITION;
		};
		
		float4x4 _WorldViewProj;
		float4x4 _MyLightMatrix0;
		float4x4 _MyWorld2Shadow;

		float3 _CameraForward;

		// x: scattering coef, y: extinction coef, z: range w: skybox extinction coef
		float4 _VolumetricLight;
        // x: 1 - g^2, y: 1 + g^2, z: 2*g, w: 1/4pi
        float4 _MieG;

		// x: scale, y: intensity, z: intensity offset
		float4 _NoiseData;
        // x: x velocity, y: z velocity
		float4 _NoiseVelocity;
		// x:  ground level, y: height scale, z: unused, w: unused
		float4 _HeightFog;
		//float4 _LightDir;

		float _MaxRayLength;

		int _SampleCount;

		struct v2f
		{
			float4 pos : SV_POSITION;
			float4 uv : TEXCOORD0;
			float3 wpos : TEXCOORD1;
		};

		v2f vert(appdata v)
		{
			v2f o;
			o.pos = mul(_WorldViewProj, v.vertex);
			o.uv = ComputeScreenPos(o.pos);
			o.wpos = mul(unity_ObjectToWorld, v.vertex);
			return o;
		}

		UNITY_DECLARE_SHADOWMAP(_CascadeShadowMapTexture);

		float GetLightAttenuation(float3 wpos)
		{
			float atten = 0;		
			#if defined (SPOT)	
			float3 tolight = _LightPos.xyz - wpos;
			half3 lightDir = normalize(tolight);

			float4 uvCookie = mul(_MyLightMatrix0, float4(wpos, 1));
			// negative bias because http://aras-p.info/blog/2010/01/07/screenspace-vs-mip-mapping/
			atten = tex2Dbias(_LightTexture0, float4(uvCookie.xy / uvCookie.w, 0, -8)).w;
			atten *= uvCookie.w < 0;
			float att = dot(tolight, tolight) * _LightPos.w;
			atten *= tex2D(_LightTextureB0, att.rr).UNITY_ATTEN_CHANNEL;

			#if defined(SHADOWS_DEPTH)
			float4 shadowCoord = mul(_MyWorld2Shadow, float4(wpos, 1));
			atten *= saturate(UnitySampleShadowmap(shadowCoord));
			#endif

			#endif
			return atten;
		}

        void ApplyHeightFog(float3 wpos, inout float density)
        {
#ifdef HEIGHT_FOG
            density *= exp(-(wpos.y + _HeightFog.x) * _HeightFog.y);
#endif
        }

		float GetDensity(float3 wpos)
		{
            float density = 1;
#ifdef NOISE
			float noise = tex3D(_NoiseTexture, frac(wpos * _NoiseData.x + float3(_Time.y * _NoiseVelocity.x, 0, _Time.y * _NoiseVelocity.y)));
			noise = saturate(noise - _NoiseData.z) * _NoiseData.y;
			density = saturate(noise);
#endif
            ApplyHeightFog(wpos, density);

            return density;
		}        

		float MieScattering(float cosAngle, float4 g)
		{
            return g.w * (g.x / (pow(g.y - g.z * cosAngle, 1.5)));			
		}

		float4 RayMarch(float2 screenPos, float3 rayStart, float3 rayDir, float rayLength)
		{
			float2 interleavedPos = (fmod(floor(screenPos.xy), 8.0));
			float offset = tex2D(_DitherTexture, interleavedPos / 8.0 + float2(0.5 / 8.0, 0.5 / 8.0)).w;

			int stepCount = _SampleCount;

			float stepSize = rayLength / stepCount;
			float3 step = rayDir * stepSize;

			float3 currentPosition = rayStart + step * offset;

			float4 vlight = 0;

			float cosAngle;
			// we don't know about density between camera and light's volume, assume 0.5
			float extinction = length(_WorldSpaceCameraPos - currentPosition) * _VolumetricLight.y * 0.5;

			[loop]
			for (int i = 0; i < stepCount; ++i)
			{
				float atten = GetLightAttenuation(currentPosition);
				float density = GetDensity(currentPosition);

                float scattering = _VolumetricLight.x * stepSize * density;
				extinction += _VolumetricLight.y * stepSize * density;// +scattering;

				float4 light = atten * scattering * exp(-extinction);


				// phase functino for spot and point lights
                float3 tolight = normalize(currentPosition - _LightPos.xyz);
                cosAngle = dot(tolight, -rayDir);
				light *= MieScattering(cosAngle, _MieG);

				vlight += light;

				currentPosition += step;				
			}

			// apply light's color
			vlight *= _LightColor;

			vlight = max(0, vlight);
            vlight.w = 0;
			return vlight;
		}

		float2 RayConeIntersect(in float3 f3ConeApex, in float3 f3ConeAxis, in float fCosAngle, in float3 f3RayStart, in float3 f3RayDir)
		{
			float inf = 10000;
			f3RayStart -= f3ConeApex;
			float a = dot(f3RayDir, f3ConeAxis);
			float b = dot(f3RayDir, f3RayDir);
			float c = dot(f3RayStart, f3ConeAxis);
			float d = dot(f3RayStart, f3RayDir);
			float e = dot(f3RayStart, f3RayStart);
			fCosAngle *= fCosAngle;
			float A = a*a - b*fCosAngle;
			float B = 2 * (c*a - d*fCosAngle);
			float C = c*c - e*fCosAngle;
			float D = B*B - 4 * A*C;

			if (D > 0)
			{
				D = sqrt(D);
				float2 t = (-B + sign(A)*float2(-D, +D)) / (2 * A);
				bool2 b2IsCorrect = c + a * t > 0 && t > 0;
				t = t * b2IsCorrect + !b2IsCorrect * (inf);
				return t;
			}
			else // no intersection
				return inf;
		}

		float RayPlaneIntersect(in float3 planeNormal, in float planeD, in float3 rayOrigin, in float3 rayDir)
		{
			float NdotD = dot(planeNormal, rayDir);
			float NdotO = dot(planeNormal, rayOrigin);

			float t = -(NdotO + planeD) / NdotD;
			if (t < 0)
				t = 100000;
			return t;
		}

		ENDCG

		// pass 0 - spot light, camera inside
		Pass
		{
			ZTest Off Cull Front ZWrite Off Blend One One

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment fragPointInside
			#pragma target 4.0

			#pragma shader_feature HEIGHT_FOG
			#pragma shader_feature NOISE
			#pragma shader_feature SHADOWS_DEPTH
			#pragma shader_feature SPOT

			fixed4 fragPointInside(v2f i) : SV_Target
			{
				float2 uv = i.uv.xy / i.uv.w;

				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);
				float linearDepth = LinearEyeDepth(depth);

				float3 rayStart = _WorldSpaceCameraPos;
				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - rayStart);
				float rayLength = length(rayDir);

				rayDir /= rayLength;

				float projectedDepth = linearDepth / dot(_CameraForward, rayDir);
				rayLength = min(rayLength, projectedDepth);

				return RayMarch(i.pos.xy, rayStart, rayDir, rayLength);
			}
			ENDCG
		}

		// pass 1 - spot light, camera outside
		Pass
		{
			ZTest Off Cull Back ZWrite Off Blend One One

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment fragSpotOutside
			#pragma target 4.0

			#pragma shader_feature HEIGHT_FOG
			#pragma shader_feature SHADOWS_DEPTH
			#pragma shader_feature NOISE
			#pragma shader_feature SPOT
			
			float _CosAngle;
			float4 _ConeAxis;
			float4 _ConeApex;
			float _PlaneD;

			fixed4 fragSpotOutside(v2f i) : SV_Target
			{
				float2 uv = i.uv.xy / i.uv.w;

				float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);

				float3 rayStart = _WorldSpaceCameraPos;
				float3 rayEnd = i.wpos;

				float3 rayDir = (rayEnd - rayStart);
				float rayLength = length(rayDir);

				rayDir /= rayLength;


				// inside cone
				float3 r1 = rayEnd + rayDir * 0.001;

				// plane intersection
				float planeCoord = RayPlaneIntersect(_ConeAxis, _PlaneD, r1, rayDir);
				// ray cone intersection
				float2 lineCoords = RayConeIntersect(_ConeApex, _ConeAxis, _CosAngle, r1, rayDir);

				float linearDepth = LinearEyeDepth(depth);
				float projectedDepth = linearDepth / dot(_CameraForward, rayDir);

				float z = (projectedDepth - rayLength);
				rayLength = min(planeCoord, min(lineCoords.x, lineCoords.y));
				rayLength = min(rayLength, z);

				return RayMarch(i.pos.xy, rayEnd, rayDir, rayLength);
			}
			ENDCG
		}		
	}
}
