function hx711_gui()
%HX711_GUI  Load cell reader/logger for an Arduino + HX711 over serial.
%
%   Expects the Arduino to send one raw reading per line as ASCII text,
%   e.g. Serial.println(scale.read());   (newline terminated)
%
%   Requires MATLAB R2019b or newer (serialport, uifigure).

    % ---------------- State ----------------
    sp        = [];          % serialport object
    factor    = NaN;         % conversion factor: value = raw / factor
    recent    = nan(1,10);   % last raw samples (used when pressing SET)
    logging   = false;
    fid       = -1;
    t0        = [];

    % ---------------- UI ----------------
    fig = uifigure('Name','HX711 Load Cell', ...
        'Position',[100 100 960 760], ...
        'CloseRequestFcn',@onClose);

    main = uigridlayout(fig,[1 2]);
    main.ColumnWidth = {330,'1x'};
    main.RowHeight   = {'1x'};

    left = uigridlayout(main,[5 1]);
    left.RowHeight = {'fit','1x','fit','fit','fit'};
    left.Padding   = [0 0 0 0];

    % --- Connection panel ---
    pConn = uipanel(left,'Title','Connection');
    gConn = uigridlayout(pConn,[2 3]);
    gConn.RowHeight   = {24,28};
    gConn.ColumnWidth = {50,'1x',70};
    uilabel(gConn,'Text','Port');
    portDD = uidropdown(gConn,'Items',{'(none)'});
    refreshBtn = uibutton(gConn,'Text','Refresh', ...
        'ButtonPushedFcn',@(~,~)refreshPorts());
    connectBtn = uibutton(gConn,'Text','Connect', ...
        'ButtonPushedFcn',@(~,~)toggleConnection());
    connectBtn.Layout.Column = [1 3];
    
    % --- Instructions ---
    pInst = uipanel(left,'Title','Instructions');
    gInst = uigridlayout(pInst,[1 1]);
    uilabel(gInst, ...
        'Text',sprintf('E+ is Red\nE- is Black\nA+ is Green\nA- is White\nYellow/Bare Wire can go to either of the other 2 ports\n\nTo zero, power cycle.'), ...
        'WordWrap','on', ...
        'VerticalAlignment','top');

    % --- Calibration ---
    pCal = uipanel(left,'Title','Calibration');
    gCal = uigridlayout(pCal,[3 3]);
    gCal.RowHeight   = {24,24,28};
    gCal.ColumnWidth = {90,'1x',70};
    uilabel(gCal,'Text','Known value');
    knownField = uieditfield(gCal,'numeric','Value',0);
    setBtn = uibutton(gCal,'Text','SET','Enable','off', ...
        'ButtonPushedFcn',@(~,~)setFactor());
    uilabel(gCal,'Text','Units');
    unitsField = uieditfield(gCal,'text','Value','lbs', ...
        'ValueChangedFcn',@(~,~)refreshUnits());
    uilabel(gCal,'Text','');
    factorLabel = uilabel(gCal,'Text','Conversion factor: not set');
    factorLabel.Layout.Column = [1 3];

    % --- Live readout ---
    pLive = uipanel(left,'Title','Live value');
    gLive = uigridlayout(pLive,[2 1]);
    gLive.RowHeight = {50,20};
    valueLabel = uilabel(gLive,'Text','Conversion not set', ...
        'FontSize',24,'FontWeight','bold', ...
        'HorizontalAlignment','center');
    rawLabel = uilabel(gLive,'Text','Raw: --', ...
        'HorizontalAlignment','center','FontColor',[0.4 0.4 0.4]);

    % --- Logging ---
    pLog = uipanel(left,'Title','Logging');
    gLog = uigridlayout(pLog,[2 1]);
    gLog.RowHeight = {28,20};
    logBtn = uibutton(gLog,'Text','Start logging','Enable','off', ...
    'Tooltip','Connect and set the conversion factor first', ...
    'ButtonPushedFcn',@(~,~)toggleLogging());
    logStatus = uilabel(gLog,'Text','Not logging', ...
        'HorizontalAlignment','center');

    % --- Graph (right side, visible only while logging) ---
    right = uigridlayout(main,[1 1]);
    right.Padding = [0 0 0 0];
    ax = uiaxes(right);
    xlabel(ax,'Time (s)');
    grid(ax,'on');
    ln = animatedline(ax,'LineWidth',1.5,'MaximumNumPoints',20000);
    ax.Visible = 'off';
    ln.Visible = 'off';

    refreshPorts();

    % ---------------- Callbacks ----------------
    function refreshPorts()
        ports = serialportlist("available");
        if isempty(ports)
            portDD.Items = {'(none)'};
        else
            portDD.Items = cellstr(ports);
        end
    end

    function toggleConnection()
        if isempty(sp)
            port = portDD.Value;
            if strcmp(port,'(none)')
                uialert(fig,'No COM port selected.','Connection');
                return
            end
            try
                sp = serialport(port,115200);
                configureTerminator(sp,"LF");
                flush(sp);
                recent(:) = NaN;
                configureCallback(sp,"terminator",@onSerial);
            catch err
                sp = [];
                uialert(fig,err.message,'Connection failed');
                return
            end
            connectBtn.Text = 'Disconnect';
            portDD.Enable = 'off';
            refreshBtn.Enable = 'off';
            setBtn.Enable = 'on';
            updateLogBtn();
        else
            disconnect();
        end
    end

    function disconnect()
        if logging, stopLogging(); end
        if ~isempty(sp)
            try, configureCallback(sp,"off"); end %#ok<TRYNC>
            delete(sp);
            sp = [];
        end
        if isvalid(fig)
            connectBtn.Text = 'Disconnect';
            connectBtn.Text = 'Connect';
            portDD.Enable = 'on';
            refreshBtn.Enable = 'on';
            setBtn.Enable = 'off';
            rawLabel.Text = 'Raw: --';
            if isnan(factor)
                valueLabel.Text = 'Conversion not set';
            else
                valueLabel.Text = '--';
            end
            updateLogBtn();
        end
    end

    function onSerial(src,~)
        try
            txt = readline(src);
            raw = str2double(strtrim(txt));
        catch
            return
        end
        if isnan(raw), return, end

        recent = [recent(2:end) raw];
        rawLabel.Text = sprintf('Raw: %.2f',raw);

        if isnan(factor)
            conv = NaN;
            valueLabel.Text = 'Conversion not set';
        else
            conv = raw / factor;
            valueLabel.Text = sprintf('%.3f %s',conv,unitsField.Value);
        end

        if logging
            t = toc(t0);
            if isnan(conv), convStr = ''; else, convStr = sprintf('%.6f',conv); end
            fprintf(fid,'%s,%.3f,%.6f,%s\n', ...
                datestr(now,'yyyy-mm-dd HH:MM:SS.FFF'),t,raw,convStr);
            if isnan(conv), addpoints(ln,t,raw); else, addpoints(ln,t,conv); end
            drawnow limitrate
        end
    end

    function setFactor()
        known = knownField.Value;
        if isnan(known) || known == 0
            uialert(fig,'Enter a non-zero known value.','Calibration');
            return
        end
        if all(isnan(recent))
            uialert(fig,'No data received yet.','Calibration');
            return
        end
        factor = mean(recent,'omitnan') / known;
        factorLabel.Text = sprintf('Conversion factor: %.6g (raw per %s)', ...
            factor,unitsField.Value);
        updateLogBtn();
    end

    function refreshUnits()
        if ~isnan(factor)
            factorLabel.Text = sprintf('Conversion factor: %.6g (raw per %s)', ...
                factor,unitsField.Value);
        end
    end

    function updateLogBtn()
        if isempty(sp) || isnan(factor)
            logBtn.Enable = 'off';
        else
            logBtn.Enable = 'on';
        end
    end

    function toggleLogging()
        if logging, stopLogging(); else, startLogging(); end
    end

    function startLogging()
        defName = ['hx711_' datestr(now,'yyyymmdd_HHMMSS') '.csv'];
        [f,p] = uiputfile('*.csv','Save log as',defName);
        figure(fig);
        if isequal(f,0), return, end
        fid = fopen(fullfile(p,f),'w');
        if fid < 0
            uialert(fig,'Could not open file for writing.','Logging');
            return
        end
        fprintf(fid,'Timestamp,Elapsed_s,Raw,Value_%s\n',unitsField.Value);

        clearpoints(ln);
        if isnan(factor)
            ylabel(ax,'Raw');
        else
            ylabel(ax,sprintf('Load (%s)',unitsField.Value));
        end
        ax.Visible = 'on';
        ln.Visible = 'on';

        t0 = tic;
        logging = true;
        logBtn.Text = 'Stop logging';
        logStatus.Text = ['Logging to ' f];
    end

    function stopLogging()
        logging = false;
        if fid >= 0
            fclose(fid);
            fid = -1;
        end
        ax.Visible = 'off';
        ln.Visible = 'off';
        logBtn.Text = 'Start logging';
        logStatus.Text = 'Not logging';
    end

    function onClose(~,~)
        disconnect();
        delete(fig);
    end
end