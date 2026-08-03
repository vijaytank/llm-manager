import React from 'react';
import { AlertTriangle, AlertCircle, Info, ShieldAlert, Wand2 } from 'lucide-react';
import { ImpactAssessment } from '../lib/validation';
import { useConfigStore } from '../store/configStore';
import './ImpactBanner.css';

interface ImpactBannerProps {
  assessment: ImpactAssessment;
}

export const ImpactBanner: React.FC<ImpactBannerProps> = ({ assessment }) => {
  const { severity, title, explanation, recommendation, autoFix } = assessment;
  const { config, updateConfig, saveConfig } = useConfigStore();

  const renderIcon = () => {
    switch (severity) {
      case 'danger':
        return <ShieldAlert size={18} className="banner-icon danger" />;
      case 'caution':
        return <AlertCircle size={18} className="banner-icon caution" />;
      case 'warn':
        return <AlertTriangle size={18} className="banner-icon warn" />;
      case 'info':
      default:
        return <Info size={18} className="banner-icon info" />;
    }
  };

  const handleFix = async () => {
    if (autoFix && config) {
      const fixedConfig = autoFix.applyFix(config);
      updateConfig(fixedConfig);
      await saveConfig();
    }
  };

  return (
    <div className={`impact-banner severity-${severity}`}>
      <div className="banner-header">
        {renderIcon()}
        <span className="banner-title">{title}</span>
        {autoFix && (
          <button className="fix-auto-btn" onClick={handleFix}>
            <Wand2 size={12} /> Fix Automatically
          </button>
        )}
      </div>
      <div className="banner-explanation">{explanation}</div>
      <div className="banner-recommendation">
        <strong>Recommendation:</strong> {recommendation}
      </div>
    </div>
  );
};
