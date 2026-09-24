
# ---------------------------------------------------------------------
# 6.  XAML  (gebruikersinterface)
# ---------------------------------------------------------------------

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Video naar H.265 / HEVC - Batch Converter"
        Width="1200" Height="900" MinWidth="980" MinHeight="780"
        WindowStartupLocation="CenterScreen"
        Background="#FF1B1D21"
        UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">

  <Window.TaskbarItemInfo>
    <TaskbarItemInfo x:Name="taskbar"/>
  </Window.TaskbarItemInfo>

  <Window.Resources>

    <SolidColorBrush x:Key="Bg"      Color="#FF1B1D21"/>
    <SolidColorBrush x:Key="Panel"   Color="#FF25282E"/>
    <SolidColorBrush x:Key="Panel2"  Color="#FF2E323A"/>
    <SolidColorBrush x:Key="Line"    Color="#FF3A3F49"/>
    <SolidColorBrush x:Key="Fg"      Color="#FFE8EAED"/>
    <SolidColorBrush x:Key="Dim"     Color="#FF9AA3B0"/>
    <SolidColorBrush x:Key="Accent"  Color="#FF4C9AFF"/>
    <SolidColorBrush x:Key="Ok"      Color="#FF4CC38A"/>
    <SolidColorBrush x:Key="Warn"    Color="#FFE3B341"/>
    <SolidColorBrush x:Key="Err"     Color="#FFE5534B"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize"   Value="11"/>
      <Setter Property="Margin"     Value="0,0,0,2"/>
    </Style>

    <Style x:Key="StatValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize"   Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style TargetType="GroupBox">
      <Setter Property="Foreground"  Value="{StaticResource Dim}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily"  Value="Segoe UI"/>
      <Setter Property="FontSize"    Value="11"/>
      <Setter Property="Padding"     Value="8"/>
      <Setter Property="Margin"      Value="0"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="4"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF3A3F49"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#FF474D59"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#FF23262B"/>
                <Setter Property="Foreground" Value="#FF666C78"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#FF2C5FA8"/>
      <Setter Property="BorderBrush" Value="#FF3C74C4"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="#FF15171A"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="5,4"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,3,0,3"/>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#FF101215"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="4,3"/>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="#FF15171A"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="18"/>
      <Setter Property="Background" Value="#FF15171A"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Background="Transparent" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource Fg}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{StaticResource Fg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#FF15171A"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#FF2A2E35"/>
      <Setter Property="RowBackground" Value="#FF15171A"/>
      <Setter Property="AlternatingRowBackground" Value="#FF191C20"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="RowHeight" Value="24"/>
      <Setter Property="EnableRowVirtualization" Value="True"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#FF25282E"/>
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="6,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#FF2C3E5A"/>
        </Trigger>
      </Style.Triggers>
    </Style>

  </Window.Resources>

  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- ================= KOP ================= -->
    <Grid Grid.Row="0" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Text="VIDEO  -  H.265 / HEVC" FontSize="19" FontWeight="Light"/>
        <TextBlock x:Name="txtSubTitle" Text="Batch converter" Foreground="{StaticResource Dim}" FontSize="11"/>
      </StackPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock x:Name="txtFfmpegState" Text="ffmpeg: controleren…" Foreground="{StaticResource Dim}" FontSize="11" Margin="0,0,10,0"/>
      </StackPanel>
    </Grid>

    <!-- ================= MAPPEN + INSTELLINGEN ================= -->
    <Grid Grid.Row="1" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="430"/>
      </Grid.ColumnDefinitions>

      <GroupBox Grid.Column="0" Header="  BRONMAPPEN  (lokale paden en UNC, sleep mappen hierheen)  ">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <ListBox x:Name="lstFolders" Grid.Row="0" Height="128"
                   SelectionMode="Extended" AllowDrop="True"
                   ScrollViewer.HorizontalScrollBarVisibility="Auto"/>

          <Grid Grid.Row="1" Margin="0,6,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="txtPath" Grid.Column="0" Margin="0,0,6,0"
                     ToolTip="Typ of plak een pad, bv.  \\10.0.0.242\e\serie\Anime\Dorohedoro"/>
            <Button x:Name="btnAddPath" Grid.Column="1" Content="Pad toevoegen" Margin="0"/>
          </Grid>

          <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,6,0,0">
            <Button x:Name="btnBrowse" Content="Map kiezen…"/>
            <Button x:Name="btnRemoveFolder" Content="Selectie verwijderen"/>
            <Button x:Name="btnClearFolders" Content="Alles wissen"/>
          </StackPanel>
        </Grid>
      </GroupBox>

      <GroupBox Grid.Column="2" Header="  INSTELLINGEN  ">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock Grid.Row="0" Grid.Column="0" Text="Encoder" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <ComboBox x:Name="cmbCodec" Grid.Row="0" Grid.Column="1" Margin="0,0,0,4"/>

          <TextBlock Grid.Row="1" Grid.Column="0" Text="Preset" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <ComboBox x:Name="cmbPreset" Grid.Row="1" Grid.Column="1" Margin="0,0,0,4"/>

          <TextBlock Grid.Row="2" Grid.Column="0" Text="Kwaliteit (CRF)" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <Grid Grid.Row="2" Grid.Column="1" Margin="0,0,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Slider x:Name="sldCrf" Grid.Column="0" Minimum="0" Maximum="51" Value="23"
                    TickFrequency="1" IsSnapToTickEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="txtCrf" Grid.Column="1" Text="23" Width="28" TextAlignment="Right"
                       FontFamily="Consolas" FontSize="13" FontWeight="SemiBold" Margin="6,0,0,0"/>
          </Grid>

          <TextBlock Grid.Row="3" Grid.Column="0" Text="Geluid" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <ComboBox x:Name="cmbAudio" Grid.Row="3" Grid.Column="1" Margin="0,0,0,4"
                    ToolTip="Kopieren neemt de tijdstempels van het origineel over; opnieuw encoderen maakt ze opnieuw aan en vult gaten met stilte."/>

          <TextBlock Grid.Row="4" Grid.Column="0" Text="Extensies" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <TextBox x:Name="txtExt" Grid.Row="4" Grid.Column="1" Margin="0,0,0,4"/>

          <TextBlock Grid.Row="5" Grid.Column="0" Text="Werkmap" Style="{StaticResource Label}" Margin="0,0,8,4" VerticalAlignment="Center"/>
          <Grid Grid.Row="5" Grid.Column="1" Margin="0,0,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="txtWork" Grid.Column="0" Margin="0,0,6,0"/>
            <Button x:Name="btnCleanTemp" Grid.Column="1" Content="Opruimen" Margin="0" Padding="8,4"
                    ToolTip="Verwijder achtergebleven tijdelijke bestanden van eerdere runs"/>
          </Grid>

          <StackPanel Grid.Row="6" Grid.Column="0" Grid.ColumnSpan="2" Margin="0,4,0,0">
            <CheckBox x:Name="chkDeleteOrig" Content="Origineel verwijderen na geslaagde verplaatsing" IsChecked="True"/>
            <CheckBox x:Name="chkSubs"       Content="Ondertitels meenemen naar de nieuwe naam" IsChecked="True"/>
            <CheckBox x:Name="chkExitAfter"  Content="Programma afsluiten na conversie stop" IsChecked="False"/>
            <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
              <CheckBox x:Name="chkWatch" Content="Opnieuw kijken als de wachtrij leeg is, elke" IsChecked="False" VerticalAlignment="Center"
                        ToolTip="Kijkt na het ingestelde aantal uur zonder werk of er nieuwe bestanden in de bronmappen staan en zet die meteen om. Geen meldingen; laat het gewoon aanstaan."/>
              <TextBox x:Name="txtWatchHours" Width="40" Margin="6,0,4,0" Text="24" TextAlignment="Center" VerticalAlignment="Center"
                       ToolTip="Aantal uur zonder werk voordat de bronmappen opnieuw worden doorzocht (1-168)."/>
              <TextBlock Text="uur" VerticalAlignment="Center"/>
            </StackPanel>
            <!-- Kort gehouden: de kolom is 430 breed, en vinkje plus knop moeten
                 op een regel passen. De uitleg staat in de tooltip. -->
            <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
              <CheckBox x:Name="chkRenameAfter" Content="Na conversie hernoemen" IsChecked="False" VerticalAlignment="Center"
                        ToolTip="Het omgezette bestand en zijn ondertitels krijgen na de conversie een eenduidige naam volgens de naamregels, bijvoorbeeld Serienaam.S01E05.Titel.mkv. De regels staan onder RenameRules in het instellingenbestand."/>
              <Button x:Name="btnRename" Content="Bronmappen hernoemen…" Margin="12,0,0,0" Padding="8,1" VerticalAlignment="Center"
                      ToolTip="Alle video's en ondertitels in de gekozen bronmappen volgens de naamregels hernoemen. Je krijgt eerst een overzicht te zien; dubbelen gaan naar de Prullenbak. Er komt een undo-bestand bij."/>
            </StackPanel>
          </StackPanel>
        </Grid>
      </GroupBox>
    </Grid>

    <!-- ================= BEDIENING ================= -->
    <Border Grid.Row="2" Background="{StaticResource Panel}" CornerRadius="5" Padding="10" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal">
          <Button x:Name="btnScan"      Content="1.  Scannen" Width="130"/>
          <Button x:Name="btnStart"     Content="2.  Start conversie" Style="{StaticResource PrimaryButton}" Width="190"/>
          <Border Width="1" Background="{StaticResource Line}" Margin="8,2,14,2"/>
          <Button x:Name="btnPause"     Content="Pauze"      IsEnabled="False" Width="110"/>
          <Button x:Name="btnStopAfter" Content="Stop na huidige" IsEnabled="False" Width="150"/>
          <Button x:Name="btnStopNow"   Content="Stop direct" IsEnabled="False" Width="120"/>
        </StackPanel>
        <TextBlock x:Name="txtScanState" Grid.Column="1" Text="" Style="{StaticResource Label}"
                   Margin="14,0,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </Grid>
    </Border>

    <!-- ================= VOORTGANG ================= -->
    <Border Grid.Row="3" Background="{StaticResource Panel}" CornerRadius="5" Padding="12" Margin="0,0,0,10">
      <StackPanel>
        <Grid Margin="0,0,0,3">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="txtOverallLabel" Grid.Column="0" Text="Totale voortgang" Style="{StaticResource Label}"/>
          <TextBlock x:Name="txtOverallInfo"  Grid.Column="1" Text="0 / 0" Style="{StaticResource Label}"/>
        </Grid>
        <ProgressBar x:Name="pbOverall" Minimum="0" Maximum="100" Value="0"/>

        <Grid Margin="0,10,0,3">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="txtCurrentFile" Grid.Column="0" Text="Geen actieve conversie"
                     TextTrimming="CharacterEllipsis" FontSize="12"/>
          <TextBlock x:Name="txtCurrentInfo" Grid.Column="1" Text="" Style="{StaticResource Label}" Margin="10,0,0,0"/>
        </Grid>
        <ProgressBar x:Name="pbCurrent" Minimum="0" Maximum="100" Value="0" Foreground="{StaticResource Ok}"/>
      </StackPanel>
    </Border>

    <!-- ================= STATISTIEK ================= -->
    <Border Grid.Row="4" Background="{StaticResource Panel}" CornerRadius="5" Padding="12" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,10,10">
          <TextBlock Text="REKENTIJD (actief)" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stActive" Text="00:00:00" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,10,10">
          <TextBlock Text="VERSTREKEN / GEPAUZEERD" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stWall" Text="00:00:00" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="2" Margin="0,0,10,10">
          <TextBlock Text="RESTEREND (ongeveer)" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stEta" Text="--:--" Style="{StaticResource StatValue}" Foreground="{StaticResource Accent}"/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="3" Margin="0,0,10,10">
          <TextBlock Text="KLAAR OMSTREEKS" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stEtaClock" Text="--:--" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="4" Margin="0,0,10,10">
          <TextBlock Text="GEM. ENCODE-SNELHEID" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stSpeed" Text="-" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="5" Margin="0,0,0,10">
          <TextBlock Text="BESTANDEN" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stFiles" Text="0 / 0" Style="{StaticResource StatValue}"/>
        </StackPanel>

        <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,10,0">
          <TextBlock Text="ORIGINEEL TOTAAL" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stOrig" Text="0 B" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="1" Margin="0,0,10,0">
          <TextBlock Text="NA OMZETTING" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stNew" Text="0 B" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="2" Margin="0,0,10,0">
          <TextBlock Text="RUIMTEBESPARING" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stSaved" Text="0 B" Style="{StaticResource StatValue}" Foreground="{StaticResource Ok}"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="3" Margin="0,0,10,0">
          <TextBlock Text="BESPARING %" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stSavedPct" Text="0 %" Style="{StaticResource StatValue}" Foreground="{StaticResource Ok}"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="4" Margin="0,0,10,0">
          <TextBlock Text="GESLAAGD / MISLUKT" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stResult" Text="0 / 0" Style="{StaticResource StatValue}"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Grid.Column="5" Margin="0,0,0,0">
          <TextBlock Text="AANDACHT NODIG" Style="{StaticResource Label}"/>
          <TextBlock x:Name="stWarn" Text="0" Style="{StaticResource StatValue}" Foreground="{StaticResource Warn}"/>
        </StackPanel>

        <Border Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="6" Margin="0,10,0,0"
                BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="0,8,0,0">
          <StackPanel>
            <TextBlock Text="ALLE SESSIES BIJ ELKAAR" Style="{StaticResource Label}"/>
            <TextBlock x:Name="stTotals" Text="nog niets omgezet" FontFamily="Consolas" FontSize="13"/>
          </StackPanel>
        </Border>
      </Grid>
    </Border>

    <!-- ================= TABS ================= -->
    <TabControl Grid.Row="5" Background="Transparent" BorderThickness="0" Padding="0,8,0,0">
      <TabItem Header="Bestanden">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnCheckAll"   Content="Alles aanvinken" Padding="8,4"/>
            <Button x:Name="btnUncheckAll" Content="Alles uitvinken" Padding="8,4"/>
            <Button x:Name="btnCheckSel"   Content="Selectie aan" Padding="8,4"/>
            <Button x:Name="btnUncheckSel" Content="Selectie uit" Padding="8,4"/>
            <Border Width="1" Background="{StaticResource Line}" Margin="6,2,10,2"/>
            <Button x:Name="btnToTop"      Content="Naar boven"  Padding="8,4" ToolTip="Selectie bovenaan de wachtrij zetten"/>
            <Button x:Name="btnToBottom"   Content="Naar onderen" Padding="8,4" ToolTip="Selectie onderaan de wachtrij zetten"/>
            <Border Width="1" Background="{StaticResource Line}" Margin="6,2,10,2"/>
            <Button x:Name="btnRemoveSel"  Content="Selectie uit lijst" Padding="8,4"/>
            <Button x:Name="btnClearList"  Content="Lijst wissen" Padding="8,4"/>
            <TextBlock x:Name="txtSelInfo" Text="" Style="{StaticResource Label}" Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <DataGrid x:Name="grid" Grid.Row="1" IsReadOnly="False">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="" Width="34" CanUserSort="False" IsReadOnly="True">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <CheckBox IsChecked="{Binding Include, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                              IsEnabled="{Binding CanInclude, Mode=OneWay}"
                              HorizontalAlignment="Center" Margin="0"
                              ToolTip="Uitgeschakeld voor bestanden die al HEVC zijn"/>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="Nr" Binding="{Binding QueueText}" Width="54" IsReadOnly="True">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock">
                    <Setter Property="FontFamily" Value="Consolas"/>
                    <Setter Property="TextAlignment" Value="Right"/>
                    <Setter Property="Foreground" Value="#FF4C9AFF"/>
                  </Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTextColumn Header="Bestand"   Binding="{Binding Name}"         Width="*"   IsReadOnly="True"/>
              <DataGridTextColumn Header="Status"    Binding="{Binding Status}"       Width="180" IsReadOnly="True"/>
              <DataGridTextColumn Header="Grootte"   Binding="{Binding SizeText}"     Width="95"  IsReadOnly="True"/>
              <DataGridTextColumn Header="Nieuw"     Binding="{Binding NewSizeText}"  Width="95"  IsReadOnly="True"/>
              <DataGridTextColumn Header="Duur"      Binding="{Binding DurationText}" Width="80"  IsReadOnly="True"/>
              <DataGridTextColumn Header="Codec"     Binding="{Binding Codec}"        Width="75"  IsReadOnly="True"/>
              <DataGridTextColumn Header="Resultaat" Binding="{Binding ResultText}"   Width="150" IsReadOnly="True"/>
              <DataGridTextColumn Header="Map"       Binding="{Binding Folder}"       Width="240" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
      <TabItem Header="Log">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="btnSaveLog"  Content="Log opslaan…" Padding="8,4"/>
            <Button x:Name="btnClearLog" Content="Log wissen" Padding="8,4"/>
          </StackPanel>
          <TextBox x:Name="txtLog" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True"
                   TextWrapping="NoWrap" FontFamily="Consolas" FontSize="12"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                   Background="#FF101215"/>
        </Grid>
      </TabItem>
    </TabControl>

    <!-- ================= STATUSBALK ================= -->
    <Border Grid.Row="6" Background="{StaticResource Panel}" CornerRadius="4" Padding="8,5" Margin="0,10,0,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="txtStatus" Grid.Column="0" Text="Klaar." Foreground="{StaticResource Dim}" FontSize="11"
                   TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="txtStatus2" Grid.Column="1" Text="" Foreground="{StaticResource Dim}" FontSize="11"/>
      </Grid>
    </Border>

  </Grid>
</Window>
'@

$xamlText = $xaml.OuterXml
$reader   = New-Object System.Xml.XmlNodeReader $xaml
$win      = [Windows.Markup.XamlReader]::Load($reader)

# alle benoemde elementen ophalen
$ui = @{}
foreach ($m in [regex]::Matches($xamlText, 'x:Name="([^"]+)"')) {
    $n  = $m.Groups[1].Value
    $el = $win.FindName($n)
    if ($el) { $ui[$n] = $el }
}

# ---------------------------------------------------------------------
# 6b. Vangnet voor fouten binnen de GUI
#
#     De trap bovenaan het script dekt alleen de rechtstreeks uitgevoerde
#     code. Fouten in knop-handlers en in de klok komen bij de dispatcher
#     terecht; zonder dit vangnet zou het venster geruisloos verdwijnen.
# ---------------------------------------------------------------------

$script:FaultCount = 0

function Report-Fault {
    param([string]$Where, [string]$Message, [string]$Detail = '')

    $script:FaultCount = $script:FaultCount + 1

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $text  = "[$stamp] $Where : $Message"
    if ($Detail) { $text = $text + "`r`n" + $Detail }

    try { $sync.LogQueue.Enqueue(('[{0}] {1,-5} {2}: {3}' -f (Get-Date -Format 'HH:mm:ss'), 'FOUT', $Where, $Message)) } catch { }

    $dir = $ScriptDir
    if ([string]::IsNullOrEmpty($dir)) { $dir = $env:TEMP }
    try { Add-Content -LiteralPath (Join-Path $dir 'X265-Converter.error.log') -Value ($text + "`r`n") -Encoding UTF8 } catch { }

    if ($script:FaultCount -le 5) {
        try {
            [System.Windows.MessageBox]::Show(
                "$Where`r`n`r`n$Message`r`n`r`nHet programma probeert door te gaan. De volledige melding staat in X265-Converter.error.log naast het script.",
                'X265 Converter - fout', 'OK', 'Warning') | Out-Null
        } catch { }
    }
}

$win.Dispatcher.Add_UnhandledException({
    param($eSender, $eArgs)
    try {
        $eArgs.Handled = $true
        $ex = $eArgs.Exception
        Report-Fault 'Fout in de gebruikersinterface' $ex.Message ($ex.ToString())
    } catch { }
})
