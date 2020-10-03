Shader "Hidden/BilateralBlur"
{
	Properties
	{
        _MainTex("Texture", any) = "" {}
	}

	SubShader
	{
		Cull Off ZWrite Off ZTest Always

		CGINCLUDE
        #define DOWNSAMPLE_DEPTH_MODE 2
        #define UPSAMPLE_DEPTH_THRESHOLD 1.5f
        #define BLUR_DEPTH_FACTOR 0.5
        #define GAUSS_BLUR_DEVIATION 1.5        
        #define FULL_RES_BLUR_KERNEL_SIZE 7
        #define HALF_RES_BLUR_KERNEL_SIZE 5
        #define QUARTER_RES_BLUR_KERNEL_SIZE 6
        
		#define PI 3.1415927f

		#include "UnityCG.cginc"	

        UNITY_DECLARE_TEX2D(_CameraDepthTexture);
        UNITY_DECLARE_TEX2D(_MainTex);
        float4 _CameraDepthTexture_TexelSize;
        
		struct appdata
		{
			float4 vertex : POSITION;
			float2 uv : TEXCOORD0;
		};

		struct v2f
		{
			float2 uv : TEXCOORD0;
			float4 vertex : SV_POSITION;
		};

		v2f vert(appdata v)
		{
			v2f o;
			o.vertex = UnityObjectToClipPos(v.vertex);
			o.uv = v.uv;
			return o;
		}

		float GaussianWeight(float offset, float deviation)
		{
			float weight = 1.0f / sqrt(2.0f * PI * deviation * deviation);
			weight *= exp(-(offset * offset) / (2.0f * deviation * deviation));
			return weight;
		}

		float4 BilateralBlur(v2f input, int2 direction, Texture2D depth, SamplerState depthSampler, const int kernelRadius, float2 pixelSize)
		{
			//const float deviation = kernelRadius / 2.5;
			const float deviation = kernelRadius / GAUSS_BLUR_DEVIATION; // make it really strong

			float2 uv = input.uv;
			float4 centerColor = _MainTex.Sample(sampler_MainTex, uv);
			float3 color = centerColor.xyz;
			//return float4(color, 1);
			float centerDepth = (LinearEyeDepth(depth.Sample(depthSampler, uv)));

			float weightSum = 0;

			// gaussian weight is computed from constants only -> will be computed in compile time
            float weight = GaussianWeight(0, deviation);
			color *= weight;
			weightSum += weight;
						
			[unroll] for (int i = -kernelRadius; i < 0; i += 1)
			{
                float2 offset = (direction * i);
                float3 sampleColor = _MainTex.Sample(sampler_MainTex, input.uv, offset);
                float sampleDepth = (LinearEyeDepth(depth.Sample(depthSampler, input.uv, offset)));

				float depthDiff = abs(centerDepth - sampleDepth);
                float dFactor = depthDiff * BLUR_DEPTH_FACTOR;
				float w = exp(-(dFactor * dFactor));

				// gaussian weight is computed from constants only -> will be computed in compile time
				weight = GaussianWeight(i, deviation) * w;

				color += weight * sampleColor;
				weightSum += weight;
			}

			[unroll] for (i = 1; i <= kernelRadius; i += 1)
			{
				float2 offset = (direction * i);
                float3 sampleColor = _MainTex.Sample(sampler_MainTex, input.uv, offset);
                float sampleDepth = (LinearEyeDepth(depth.Sample(depthSampler, input.uv, offset)));

				float depthDiff = abs(centerDepth - sampleDepth);
                float dFactor = depthDiff * BLUR_DEPTH_FACTOR;
				float w = exp(-(dFactor * dFactor));
				
				// gaussian weight is computed from constants only -> will be computed in compile time
				weight = GaussianWeight(i, deviation) * w;

				color += weight * sampleColor;
				weightSum += weight;
			}

			color /= weightSum;
			return float4(color, centerColor.w);
		}
		ENDCG

		// pass 0 - horizontal blur
		Pass
		{
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment horizontalFrag
            #pragma target 4.0
			
			fixed4 horizontalFrag(v2f input) : SV_Target
			{
                return BilateralBlur(input, int2(1, 0), _CameraDepthTexture, sampler_CameraDepthTexture, FULL_RES_BLUR_KERNEL_SIZE, _CameraDepthTexture_TexelSize.xy);
			}
			ENDCG
		}

		// pass 1 - vertical blur
		Pass
		{
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment verticalFrag
            #pragma target 4.0
			
			fixed4 verticalFrag(v2f input) : SV_Target
			{
                return BilateralBlur(input, int2(0, 1), _CameraDepthTexture, sampler_CameraDepthTexture, FULL_RES_BLUR_KERNEL_SIZE, _CameraDepthTexture_TexelSize.xy);
			}
			ENDCG
		}
	}
}
