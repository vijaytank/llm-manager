import React, { useState, useRef, useEffect } from 'react';
import ReactDOM from 'react-dom';
import { Info, X } from 'lucide-react';
import './InfoTooltip.css';

export interface InfoTooltipProps {
  title: string;
  description: string;
  recommendation?: string;
  impact?: string;
}

export const InfoTooltip: React.FC<InfoTooltipProps> = ({
  title,
  description,
  recommendation,
  impact,
}) => {
  const [open, setOpen] = useState(false);
  const [coords, setCoords] = useState<{ top: number; left: number }>({ top: 0, left: 0 });
  const triggerRef = useRef<HTMLButtonElement>(null);
  const cardRef = useRef<HTMLDivElement>(null);

  const calculateCoords = () => {
    if (!triggerRef.current) return;
    const rect = triggerRef.current.getBoundingClientRect();
    const tooltipWidth = 300;
    const tooltipHeight = 220; // Estimated height for clamping

    let left = rect.left + rect.width / 2 - tooltipWidth / 2;
    // Clamp horizontal positioning inside visible viewport
    left = Math.max(16, Math.min(left, window.innerWidth - tooltipWidth - 16));

    let top = rect.top - tooltipHeight - 8;
    if (rect.top < tooltipHeight + 24) {
      // Not enough space above, position below trigger
      top = rect.bottom + 8;
    }
    // Clamp vertical positioning inside visible viewport
    top = Math.max(16, Math.min(top, window.innerHeight - tooltipHeight - 16));

    setCoords({ top, left });
  };

  const handleOpen = () => {
    calculateCoords();
    setOpen(true);
  };

  useEffect(() => {
    if (!open) return;
    const handleScrollOrResize = () => calculateCoords();
    window.addEventListener('scroll', handleScrollOrResize, true);
    window.addEventListener('resize', handleScrollOrResize);
    return () => {
      window.removeEventListener('scroll', handleScrollOrResize, true);
      window.removeEventListener('resize', handleScrollOrResize);
    };
  }, [open]);

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (
        triggerRef.current &&
        !triggerRef.current.contains(event.target as Node) &&
        cardRef.current &&
        !cardRef.current.contains(event.target as Node)
      ) {
        setOpen(false);
      }
    };
    if (open) {
      document.addEventListener('mousedown', handleClickOutside);
    }
    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
    };
  }, [open]);

  return (
    <span className="info-tooltip-wrapper">
      <button
        ref={triggerRef}
        type="button"
        className={`info-tooltip-trigger ${open ? 'active' : ''}`}
        onClick={(e) => {
          e.stopPropagation();
          if (open) setOpen(false);
          else handleOpen();
        }}
        onMouseEnter={handleOpen}
        onMouseLeave={() => setOpen(false)}
        aria-label={`Information about ${title}`}
      >
        <Info size={13} />
      </button>

      {open &&
        ReactDOM.createPortal(
          <div
            ref={cardRef}
            className="info-tooltip-card glass-card portal-tooltip"
            style={{
              position: 'fixed',
              top: `${coords.top}px`,
              left: `${coords.left}px`,
              width: '300px',
              zIndex: 999999,
            }}
          >
            <div className="info-tooltip-header">
              <span className="info-tooltip-title">{title}</span>
              <button
                type="button"
                className="info-tooltip-close"
                onClick={() => setOpen(false)}
              >
                <X size={12} />
              </button>
            </div>
            <div className="info-tooltip-body">
              <p className="info-tooltip-desc">{description}</p>
              {recommendation && (
                <div className="info-tooltip-section rec">
                  <span className="section-label">💡 System Recommendation</span>
                  <span className="section-text">{recommendation}</span>
                </div>
              )}
              {impact && (
                <div className="info-tooltip-section impact">
                  <span className="section-label">⚡ Impact</span>
                  <span className="section-text">{impact}</span>
                </div>
              )}
            </div>
          </div>,
          document.body
        )}
    </span>
  );
};
