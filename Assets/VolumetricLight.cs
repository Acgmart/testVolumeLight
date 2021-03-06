﻿using UnityEngine;
using System.Collections;
using UnityEngine.Rendering;
using System;

[RequireComponent(typeof(Light))]
public class VolumetricLight : MonoBehaviour
{
    private Light _light;
    private Material _material;
    private CommandBuffer _commandBuffer;

    [Range(1, 64)]
    public int SampleCount = 8;
    [Range(0.0f, 1.0f)]
    public float ScatteringCoef = 0.5f;
    [Range(0.0f, 0.1f)]
    public float ExtinctionCoef = 0.01f;
    [Range(0.0f, 1.0f)]
    public float SkyboxExtinctionCoef = 0.9f;
    [Range(0.0f, 0.999f)]
    public float MieG = 0.1f;
    public bool HeightFog = false;
    [Range(0, 0.5f)]
    public float HeightScale = 0.10f;
    public float GroundLevel = 0;
    public bool Noise = false;
    public float NoiseScale = 0.015f;
    public float NoiseIntensity = 1.0f;
    public float NoiseIntensityOffset = 0.3f;
    public Vector2 NoiseVelocity = new Vector2(3.0f, 3.0f);

    private bool _reversedZ = false;

    void Start()
    {
#if UNITY_5_5_OR_NEWER
        if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Direct3D11 || SystemInfo.graphicsDeviceType == GraphicsDeviceType.Direct3D12 ||
            SystemInfo.graphicsDeviceType == GraphicsDeviceType.Metal || SystemInfo.graphicsDeviceType == GraphicsDeviceType.PlayStation4 ||
            SystemInfo.graphicsDeviceType == GraphicsDeviceType.Vulkan || SystemInfo.graphicsDeviceType == GraphicsDeviceType.XboxOne)
        {
            _reversedZ = true;
        }
#endif

        _commandBuffer = new CommandBuffer();
        _commandBuffer.name = "Light Command Buffer";

        _light = GetComponent<Light>();
        _light.AddCommandBuffer(LightEvent.AfterShadowMap, _commandBuffer);

        Shader shader = Shader.Find("Sandbox/VolumetricLight");
        if (shader == null)
            throw new Exception("Critical Error: \"Sandbox/VolumetricLight\" shader is missing. Make sure it is included in \"Always Included Shaders\" in ProjectSettings/Graphics.");
        _material = new Material(shader); // new Material(VolumetricLightRenderer.GetLightMaterial());
    }

    void OnEnable()
    {
        VolumetricLightRenderer.PreRenderEvent += VolumetricLightRenderer_PreRenderEvent;
    }

    void OnDisable()
    {
        VolumetricLightRenderer.PreRenderEvent -= VolumetricLightRenderer_PreRenderEvent;
    }

    public void OnDestroy()
    {
        Destroy(_material);
    }

    private void VolumetricLightRenderer_PreRenderEvent(VolumetricLightRenderer renderer, Matrix4x4 VP)
    {
        if (_light == null || _light.gameObject == null)
            VolumetricLightRenderer.PreRenderEvent -= VolumetricLightRenderer_PreRenderEvent;
        if (!_light.gameObject.activeInHierarchy || _light.enabled == false)
            return;

        _material.SetVector("_CameraForward", Camera.current.transform.forward);

        _material.SetInt("_SampleCount", SampleCount);
        _material.SetVector("_NoiseVelocity", new Vector4(NoiseVelocity.x, NoiseVelocity.y) * NoiseScale);
        _material.SetVector("_NoiseData", new Vector4(NoiseScale, NoiseIntensity, NoiseIntensityOffset));
        _material.SetVector("_MieG", new Vector4(1 - (MieG * MieG), 1 + (MieG * MieG), 2 * MieG, 1.0f / (4.0f * Mathf.PI)));
        _material.SetVector("_VolumetricLight", new Vector4(ScatteringCoef, ExtinctionCoef, _light.range, 1.0f - SkyboxExtinctionCoef));

        _material.SetTexture("_CameraDepthTexture", null);
        _material.SetFloat("_ZTest", (int)UnityEngine.Rendering.CompareFunction.Always);

        if (HeightFog)
        {
            _material.EnableKeyword("HEIGHT_FOG");
            _material.SetVector("_HeightFog", new Vector4(GroundLevel, HeightScale));
        }
        else
        {
            _material.DisableKeyword("HEIGHT_FOG");
        }

        _commandBuffer.Clear();

        int pass = 0;
        if (!IsCameraInSpotLightBounds()) //离相机太远或者角度很偏时
            pass = 1;

        Mesh mesh = VolumetricLightRenderer.GetSpotLightMesh();

        //Spot mesh随着range变化缩放
        //长度确定为_light.range 宽度由_light.spotAngle决定
        float scale = _light.range;
        float angleScale = Mathf.Tan((_light.spotAngle + 1) * 0.5f * Mathf.Deg2Rad) * _light.range;

        Matrix4x4 world = Matrix4x4.TRS(transform.position, transform.rotation, new Vector3(angleScale, angleScale, scale));

        Matrix4x4 view = Matrix4x4.TRS(_light.transform.position, _light.transform.rotation, Vector3.one).inverse;

        Matrix4x4 clip = Matrix4x4.TRS(new Vector3(0.5f, 0.5f, 0.0f), Quaternion.identity, new Vector3(-0.5f, -0.5f, 1.0f));
        //圆形投影区aspect为1
        Matrix4x4 proj = Matrix4x4.Perspective(_light.spotAngle, 1, 0, 1);

        _material.SetMatrix("_MyLightMatrix0", clip * proj * view);

        _material.SetMatrix("_WorldViewProj", VP * world);

        _material.SetVector("_LightPos", new Vector4(_light.transform.position.x, _light.transform.position.y, _light.transform.position.z, 1.0f / (_light.range * _light.range)));
        _material.SetVector("_LightColor", _light.color * _light.intensity);


        Vector3 apex = transform.position;
        Vector3 axis = transform.forward;
        // plane equation ax + by + cz + d = 0; precompute d here to lighten the shader
        Vector3 center = apex + axis * _light.range;
        float d = -Vector3.Dot(center, axis);

        // update material
        _material.SetFloat("_PlaneD", d);
        _material.SetFloat("_CosAngle", Mathf.Cos((_light.spotAngle + 1) * 0.5f * Mathf.Deg2Rad));

        _material.SetVector("_ConeApex", new Vector4(apex.x, apex.y, apex.z));
        _material.SetVector("_ConeAxis", new Vector4(axis.x, axis.y, axis.z));

        _material.EnableKeyword("SPOT");

        if (Noise)
            _material.EnableKeyword("NOISE");
        else
            _material.DisableKeyword("NOISE");

        if (_light.cookie == null)
        {
            _material.SetTexture("_LightTexture0", VolumetricLightRenderer.GetDefaultSpotCookie());
        }
        else
        {
            _material.SetTexture("_LightTexture0", _light.cookie);
        }

        clip = Matrix4x4.TRS(new Vector3(0.5f, 0.5f, 0.5f), Quaternion.identity, new Vector3(0.5f, 0.5f, 0.5f));

        if (_reversedZ)
            proj = Matrix4x4.Perspective(_light.spotAngle, 1, _light.range, _light.shadowNearPlane);
        else
            proj = Matrix4x4.Perspective(_light.spotAngle, 1, _light.shadowNearPlane, _light.range);

        Matrix4x4 m = clip * proj;
        m[0, 2] *= -1;
        m[1, 2] *= -1;
        m[2, 2] *= -1;
        m[3, 2] *= -1;

        //view = _light.transform.worldToLocalMatrix;
        _material.SetMatrix("_MyWorld2Shadow", m * view);
        _material.SetMatrix("_WorldView", m * view);

        _material.EnableKeyword("SHADOWS_DEPTH");
        _commandBuffer.SetGlobalTexture("_ShadowMapTexture", BuiltinRenderTextureType.CurrentActive);
        _commandBuffer.SetRenderTarget(renderer.GetVolumeLightBuffer());

        _commandBuffer.DrawMesh(mesh, world, _material, 0, pass);

    }

    private bool IsCameraInSpotLightBounds()
    {
        //cosβ* distance
        float distance = Vector3.Dot(_light.transform.forward, (Camera.current.transform.position - _light.transform.position));
        float extendedRange = _light.range + 1;
        if (distance > (extendedRange))
            return false;

        //Spot光源的角度需要除以一半才能用来界定角度边界
        float cosAngle = Vector3.Dot(transform.forward, (Camera.current.transform.position - _light.transform.position).normalized);
        if ((Mathf.Acos(cosAngle) * Mathf.Rad2Deg) > (_light.spotAngle + 3) * 0.5f)
            return false;

        return true;
    }
}
