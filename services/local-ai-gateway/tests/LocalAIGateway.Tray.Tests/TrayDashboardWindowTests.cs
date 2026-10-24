using System.Threading;
using System.Windows;
using System.Windows.Controls;

namespace LocalAIGateway.Tray.Tests;

public sealed class TrayDashboardWindowTests
{
    [Fact]
    public void Dashboard_KeepsActionBarOutsideScrollableContent()
    {
        RunInSta(() =>
        {
            using var scope = new WindowScope();
            var window = scope.Window;
            var root = Assert.IsType<Grid>(window.Content);

            Assert.Equal(2, root.RowDefinitions.Count);
            Assert.Equal(GridUnitType.Star, root.RowDefinitions[0].Height.GridUnitType);
            Assert.Equal(GridUnitType.Auto, root.RowDefinitions[1].Height.GridUnitType);
            Assert.Equal(0, Grid.GetRow(window.ContentScrollViewerForTesting));
            Assert.Equal(1, Grid.GetRow(window.ActionBarForTesting));
            Assert.Equal(ScrollBarVisibility.Auto, window.ContentScrollViewerForTesting.VerticalScrollBarVisibility);
            Assert.True(window.MinWidth >= 620);
            Assert.True(window.MinHeight >= 500);
        });
    }

    [Fact]
    public void Dashboard_InitialStateExposesUsablePrimaryActions()
    {
        RunInSta(() =>
        {
            using var scope = new WindowScope();
            var window = scope.Window;

            window.Apply(TrayState.Initial);

            Assert.True(window.StartButtonForTesting.IsEnabled);
            Assert.True(window.RefreshButtonForTesting.IsEnabled);
            Assert.Equal(1, window.CircuitRowCountForTesting);
        });
    }

    [Fact]
    public void Dashboard_UsesOneChineseCapableFontFamily()
    {
        RunInSta(() =>
        {
            using var scope = new WindowScope();

            Assert.Equal("Microsoft YaHei UI", scope.Window.FontFamily.Source);
        });
    }

    [Fact]
    public void Dashboard_ProfileSelectorUsesCustomAccessibleStyle()
    {
        RunInSta(() =>
        {
            using var scope = new WindowScope();
            var selector = scope.Window.ProfileSelectorForTesting;

            Assert.NotNull(selector.Style);
            Assert.NotNull(selector.ItemContainerStyle);
            Assert.True(selector.MinHeight >= 42);
            Assert.Equal("选择 Profile", System.Windows.Automation.AutomationProperties.GetName(selector));
            Assert.True(selector.ApplyTemplate());
            Assert.NotNull(selector.Template.FindName("DropDownToggle", selector));
            Assert.NotNull(selector.Template.FindName("PART_Popup", selector));
        });
    }

    private static void RunInSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                action();
            }
            catch (Exception exception)
            {
                failure = exception;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
        {
            throw new Xunit.Sdk.XunitException(failure.ToString());
        }
    }

    private sealed class WindowScope : IDisposable
    {
        public WindowScope()
        {
            Window = new TrayDashboardWindow();
        }

        public TrayDashboardWindow Window { get; }

        public void Dispose() => Window.Close();
    }
}
